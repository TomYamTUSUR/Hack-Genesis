# Умный роутинг выплат

Механизм распределения выплат между провайдерами: hard-constraints + soft-goal стратегии рейтинга на Ruby + БД (SQLite/Sequel) для хранения провайдеров, очереди операций, истории и результатов роутинга, плюс интерактивная консоль (`bin/menu.rb`) для запуска и настройки без ручной правки файлов.

## Зависимости

- **Ruby** — проверено на 4.0.
- **Bundler** (`gem install bundler`) — ставит гемы из `Gemfile`.

Гемы (`Gemfile`/`Gemfile.lock`):

| Гем | Версия | Для чего |
|---|---|---|
| `sequel` | 5.108 | ORM/query-builder поверх SQLite — весь доменный код (`lib/payment_routing/*`) читает и пишет БД только через него |
| `sqlite3` | 2.9.6 | нативный драйвер SQLite (нужен и Sequel, и коду, который обращается к БД напрямую — `lib/canonical_database_analytics.rb`, `bin/update_provider_minute_stats.rb`) |
| `rake` | 13.4 | запуск тестов (`rake test`) |
| `minitest` | 6.0 | тестовый фреймворк |
| `csv` | 3.3 | разбор `data/operations_history.csv` при импорте |

`bundle install` дополнительно подтягивает транзитивные зависимости (`bigdecimal`, `drb`, `prism`) — руками их ставить не нужно.

## Структура проекта

- `lib/payment_routing/` — доменная логика: провайдеры/операции, блок hard-constraints (`hard_filter/`), блок стратегий (`strategies/`), блок рейтинга (`rating/`), оркестратор (`router/` — hard-constraints → рейтинг → попытки с fallback → обновление рантайм-состояния между операциями → запись состояния обратно в БД), загрузчики из БД (`ProviderRegistry`, `HistoricalActualsProvider`, `OperationQueueLoader`, `DecisionsReader`), консольное меню (`menu/`), импортёры `data/*`/`config/business_parameters.yml → БД` (`importers/`).
- `db/` — схема SQLite (`database.rb`, включая аддитивные миграции в `upgrade_schema!`) и скрипт её создания (`create_tables.rb`).
- `config/` — `routing.yml` (пути к данным для импорта, список рейтингуемых провайдеров, `active_strategies`, `fallback_provider`), `strategies.yml` (коэффициенты стратегий), `business_parameters.yml` (регулируемые бизнес-величины по провайдерам — `preferred_range_min/max`, `volume_share_pct`, `requests_per_minute_limit`, `daily_turnover_min/max` — которых нет в `data/providers.json`; временный источник, см. комментарий в файле и раздел «Изменяемые параметры» ниже).
- `data/` — исходные файлы для первичного импорта в БД (`providers.json`, `operations_history.csv`, `operations_queue_10.json`).
- `bin/` — исполняемые скрипты: `menu.rb` (интерактивное консольное меню, см. ниже), `import_data.rb` (импорт `data/*` + `config/business_parameters.yml` в БД), `route.rb` (обрабатывает очередь через Router, журналирует решения и состояние в БД, сразу собирает `routing_decisions_test.json`), `build_decisions.rb` (пересобирает `routing_decisions_test.json` из уже заполненной БД без повторного роутинга), `build_report.rb` (собирает обязательный `routing_report_test.json` из БД), `demo_rating.rb`/`demo_hard_filter.rb` (демонстрации без полного пайплайна), `analyze_db.rb`/`log_operations.rb`/`update_provider_minute_stats.rb` (аналитика, см. `SCRIPTS.md`).
- `test/` — Minitest, зеркалирует структуру `lib/`.

Рейтинг, стратегии и hard-constraints читают только БД (`db/operations.db`) — файлы в `data/`/`config/business_parameters.yml` участвуют один раз, на этапе импорта. `routing_decisions_test.json`/`routing_report_test.json` — обязательные артефакты по итогам обработки `data/operations_queue_10.json` (или другой очереди, импортированной в БД); оба всегда собираются из БД (`DecisionsReader`/`CanonicalDatabaseAnalytics`), а не напрямую из решений `Router`'а в памяти.

## Как работает движок

### Общий поток на одну операцию

```
Input → Hard Constraints → Eligible Providers → Routing Strategy (Soft Goals) → Selected Provider → Result / Fallback
```

`Router::Router#route`:

1. `RunState#advance_to(operation.created_at)` — сдвигает «текущее время» симуляции на момент операции (нужно для скользящего RPM-окна и сброса дневных счётчиков, см. ниже).
2. `HardFilter::Engine#call_all` — прогоняет всех рейтингуемых провайдеров через 9 обязательных проверок (таблица ниже). Не прошедший хотя бы одну исключается из пула на эту операцию; **все** причины запоминаются (`Result#reasons`), но в `attempts` попадает только первая сработавшая — так требует формат ответа.
3. Пул пуст → сразу fallback, причина `no_eligible_provider`.
4. Иначе — стратегии + рейтинг (формула ниже) сортируют пул по убыванию балла.
5. Кандидаты перебираются по рейтингу; отказ одного (`ProviderClient::UnavailableError`) — переход к следующему без повторных попыток на том же провайдере. Все отказали → fallback, причина `all_providers_unavailable`.
6. `OutcomeSimulator#simulate` — в v1 всегда `"approved"`.
7. `Router::MetricsUpdater` обновляет рантайм-состояние (см. «Состояние между операциями») — следующая операция очереди видит уже изменившуюся картину.
8. Собирается `Decision`: `operation_id`, `selected_provider`, `attempts[]`, `simulated_result`, `latency_sec`, `explanation` с полной трассировкой (все причины по каждому провайдеру, веса и разбивка рейтинга).

### Hard-constraints (9 правил, `lib/payment_routing/hard_filter/`)

Применяются к каждому рейтингуемому провайдеру независимо от активной стратегии, в этом порядке (`HardFilter::Engine::RULES`):

| # | Правило | Условие исключения | `reason` |
|---|---|---|---|
| 1 | Статус | `status != "active"` | `status_not_active` |
| 2 | Диапазон суммы | `amount < limit_amount_min` / `amount > limit_amount_max` | `amount_below_minimum` / `amount_exceeds_limit` |
| 3 | Дневной максимум | `daily_approved_amount + amount > daily_amount_limit` | `daily_amount_limit_exceeded` |
| 4 | In-progress | `in_progress_count ≥ in_progress_count_limit` или `in_progress_amount + amount > in_progress_amount_limit` | `in_progress_limit_exceeded` |
| 5 | Банковский фильтр | банк не проходит `banks`/`exclude_banks` (whitelist или blacklist) | `bank_not_in_list` |
| 6 | Маржа | `provider_margin_pct > merchant_margin_pct` и нет `allow_negative_agreement` | `margin_not_acceptable` |
| 7 | Реквизиты | `available_requisites == 0` | `no_available_requisites` |
| 8 | Интенсивность | `rpm_used ≥ requests_per_minute_limit` (скользящее окно 60 сек) | `rate_limit_exceeded` |
| 9 | Фин. обязательство (максимум) | `turnover_actual + amount > daily_turnover_max` | `daily_turnover_max_exceeded` |

Лимит, равный `nil`, значит «без ограничения» — правило пропускается (кроме `banks: []`, которое явно значит «без ограничения по банкам»).

### Soft-goals: как считается рейтинг (`lib/payment_routing/rating/`, `lib/payment_routing/strategies/`)

Балл допустимого (прошедшего hard-constraints) провайдера `p`:

```
Score(p) = 100 × [ Σᵢ wᵢ · normᵢ(p) ] × LoadFactor(p)^γ
```

**Веса `wᵢ`** (`Strategies::StrategyWeightCalculator`, список активных — `active_strategies` в `config/routing.yml`):
- **Соло-режим** (1 активная стратегия): у неё вес `0.70` (`SOLO_TARGET_WEIGHT`), у остальных шести — поровну от `0.30` (`SOLO_OTHERS_TOTAL_WEIGHT`), но не меньше `0.05` каждой (`SOLO_OTHER_MIN_WEIGHT`).
- **Комбо-режим** (2+ активных): `wᵢ = combo_coefficientᵢ / Σ combo_coefficient активных` (коэффициенты — `config/strategies.yml`); неактивные получают `0`.

**Нормы `normᵢ(p)`** (`lib/payment_routing/rating/norms/*.rb`, один файл на стратегию, шкала `[0,1]`):

| Стратегия | Норма | Целевое поле |
|---|---|---|
| `count_share` | `deviation_norm(target: traffic_percentage, actual: count_share_actual)` | `traffic_percentage` |
| `volume_share` | `deviation_norm(target: volume_share_pct, actual: volume_share_actual)` | `volume_share_pct` |
| `priority` | min-max по пулу: чем меньше `priority`, тем ближе к 1 | `priority` |
| `range_fit` | `1 − |amount − mid(preferred_range)| / halfwidth(preferred_range)`, клип в `[0,1]` | `preferred_range_min/max` |
| `conversion` | min-max по `conversion_24h` **внутри текущего допустимого пула** (без сохранённой цели, чисто относительно конкурентов) | `conversion_24h` |
| `intensity` | `1 − rpm_used / requests_per_minute_limit` (только rpm-измерение, отдельно от общего `LoadFactor`) | `requests_per_minute_limit` |
| `turnover` | `deviation_norm(target: daily_turnover_min, actual: turnover_actual)` | `daily_turnover_min` |

Общая формула `deviation_norm` (count_share/volume_share/turnover):
```
rd   = clip((target − actual) / target, −1, 1)
norm = (rd + 1) / 2
```
Провайдер, не набравший цель (`actual < target`), получает `norm > 0.5` (приоритет растёт); перебравший — `norm < 0.5` (приоритет падает); точно в цели → `0.5`.

**Важный нюанс про отсутствующую цель:** для `count_share`/`volume_share` при `target = nil`/`0` норма (сам `deviation_norm`) возвращает не нейтральные `0.5`, а **максимум `1.0`** (`Constants::SINGLE_CANDIDATE_NORM`) — то есть провайдер без настроенной цели получает по этому критерию лучший, а не средний балл. У `turnover` и `conversion` — отдельная явная защита именно на нейтральные `0.5` (`Constants::NEUTRAL_NORM`) для своего случая «нет данных» (`daily_turnover_min`/`conversion_24h` не заданы). У `range_fit` и `intensity` отсутствие `preferred_range`/`requests_per_minute_limit` тоже даёт максимум `1.0`, а не штраф и не нейтраль. Иначе говоря: не задать бизнес-параметр для стратегии почти везде значит «дать максимум», а не «наказать» или оставить нейтральным.

**`LoadFactor(p)^γ`** (`Rating::LoadFactorCalculator`) — общий штраф за загрузку, действует при любой активной стратегии:
```
utilization = max(rpm_used/rpm_limit, in_progress_count/count_limit, in_progress_amount/amount_limit)   # по тем измерениям, где лимит задан
LoadFactor  = (1 − utilization) ^ γ
```
`γ = 2` по умолчанию, `γ = 4`, если среди активных — `intensity` (сильнее давит на загруженных). Провайдер без единого лимита получает `utilization = 0` → `LoadFactor = 1` (без штрафа).

### Состояние между операциями (`Router::RunState`, `Router::MetricsUpdater`)

Очередь обрабатывается последовательно; состояние провайдеров реально меняется от операции к операции, а не берётся статичным снимком на начало прогона:

- **`in_progress_count/amount`** — растут перед обращением к провайдеру (`start_attempt`) и уменьшаются сразу после (`finish_attempt`) — заняты только на время самого обращения, в том числе внутри одной операции при каскаде.
- **`daily_approved_amount`/`turnover_actual`** — растут на сумму операции, если она approved.
- **`count_share_actual`/`volume_share_actual`** — пересчитываются заново у **всех** рейтингуемых провайдеров (включая fallback) после каждой approved-операции, не только у выбранного — это доли от общего количества/объёма, поэтому меняются у всех сразу.
- **Дневной оборот сбрасывается по календарным суткам** конкретного провайдера: `RunState#advance_to` при смене дня (с учётом `daily_utc_offset`) обнуляет `daily_approved_amount`/`turnover_actual`.
- **`rpm_used`** — реальное скользящее окно 60 секунд (`Constants::RPM_WINDOW_SECONDS`) по фактическим обращениям, а не статичный снимок из истории на старте.

По завершении прогона `Router::StateWriter` пишет `in_progress_count/amount`, `daily_approved_amount`, `daily_approved_date`, `daily_utc_offset` обратно в таблицу `providers` — иначе следующий запуск стартовал бы заново с исходных значений `data/providers.json`.

### Fallback и симуляция исхода

- Пул пуст или все кандидаты отказали → выбирается self-provider (`fallback_provider` в `config/routing.yml`, сейчас `spacepayments`) — он тоже проходит все hard-constraints как обычный провайдер, просто остаётся единственным кандидатом, если весь остальной пул отсеян.
- `Router::OutcomeSimulator` в v1 **всегда** возвращает `"approved"` — реальная модель исхода (например, на основе `conversion_24h`) не реализована; это осознанное, явно зафиксированное упрощение, а не недосмотр.

## Установка и запуск

### Шаги

```
bundle install                          # зависимости (см. «Зависимости» выше)
bundle exec ruby db/create_tables.rb    # создать схему в db/operations.db
bundle exec ruby bin/import_data.rb     # загрузить data/* + business_parameters.yml в БД (провайдеры - до history)
bundle exec ruby bin/demo_rating.rb     # прогнать несколько стратегий и посмотреть ранжирование
bundle exec ruby bin/demo_hard_filter.rb # прогнать hard-constraints по каждому правилу (без БД)
bundle exec ruby bin/route.rb           # обработать очередь, записать решения/состояние в БД и собрать routing_decisions_test.json
bundle exec ruby bin/build_report.rb    # собрать routing_report_test.json из БД
bundle exec rake test                   # тесты (или просто `rake test`, без bundler)
```

Импорт можно делать по частям: `bundle exec ruby bin/import_data.rb providers history`.

### Консольное меню

`bundle exec ruby bin/menu.rb [--database PATH]` (или `menu.bat` в корне проекта на Windows) — интерактивная альтернатива шагам выше: запуск роутинга (сразу с отчётом), переключение активных стратегий, импорт/замена/очистка данных, редактирование бизнес-параметров провайдеров и весов стратегий — без ручных вызовов скриптов и правки `config/*.yml`.

1. **Start Route** — требует хотя бы одну активную стратегию и непустые `providers`/`operations_queue`/`operations_history`; иначе следующий экран объясняет, чего не хватает. При успехе сразу собирает оба обязательных артефакта — `routing_decisions_test.json` и `routing_report_test.json` (отдельного пункта меню для отчёта нет).
2. **Switch strategies** — список всех 7 стратегий с отметкой `[x]`/`[ ]`; можно переключить несколько сразу одной строкой через пробел/запятую (например `1, 3, 5`).
3. **Data** → Update (добавляет/обновляет записи по естественному ключу, не дублирует) / Replace (очищает конкретную таблицу и грузит файл заново) / Clear (очищает всю БД).
4. **Provider metrics** (self-provider/fallback в списке не показывается — для него эти поля не применимы) — правки сначала попадают в `config/business_parameters.yml` (точечно, построчно — комментарии в файле не стираются), затем сразу переносятся в БД. Отрицательные значения и проценты выше 100 отклоняются; ввод слова `clear` вместо числа сбрасывает поле в «не задано».
5. **Strategies priority** — правит `combo_coefficient` в `config/strategies.yml` тем же точечным способом.
6. **Clear mode** — если включён, сразу после того как Start Route обработает очередь (и запишет оба файла), БД возвращается к исходным данным: все таблицы очищаются и заново заполняются из `data/*` + `config/business_parameters.yml`, как будто прогона не было. Правки `config/*.yml`, сделанные во время сессии, этим не откатываются — откатывается только содержимое БД.

Навигация: ввод номера открывает следующий уровень меню; пустой ввод (Enter) возвращает на уровень выше (на главном экране — ничего не делает); после переключения/ввода значения показывается сообщение и ожидание любой клавиши, затем возврат на экран, с которого действие было вызвано. Выход из меню — только Ctrl+C (пункта «выход» нет).

## Изменяемые параметры

| Параметр | Где хранится | Как менять |
|---|---|---|
| Активные стратегии | `config/routing.yml#active_strategies` | Меню → **Switch strategies**, либо правка YAML вручную |
| Веса combo-режима (`combo_coefficient`) | `config/strategies.yml` | Меню → **Strategies priority**, либо вручную |
| `volume_share_pct`, `preferred_range_min/max`, `requests_per_minute_limit`, `daily_turnover_min/max` | `config/business_parameters.yml` → таблица `providers` | Меню → **Provider metrics** (в т.ч. `clear` — сбросить поле), либо правка YAML вручную (подхватится при следующем Route или открытии Provider metrics) |
| Данные конкретной таблицы (`providers`/`operations_queue`/`operations_history`) | `data/*.json`, `data/*.csv` | Меню → **Data → Update/Replace**, либо `bin/import_data.rb` |
| Вся БД целиком | — | Меню → **Data → Clear**, либо пересоздать файл (`db/create_tables.rb`) |
| Список рейтингуемых провайдеров (`rated_providers`), self-provider (`fallback_provider`), пути к исходным файлам импорта | `config/routing.yml` | Только вручную — пункта в меню нет |
| `traffic_percentage`, `priority` и все hard-constraint-лимиты (`limit_amount_*`, `daily_amount_limit`, `in_progress_*_limit`, `banks`, `exclude_banks`, `provider_margin_pct`, `merchant_margin_pct`, `allow_negative_agreement`, `available_requisites`, `conversion_24h`, `avg_latency_sec`) | `data/providers.json` → таблица `providers` | Замена файла + **Data → Replace** (таблица `providers`), либо `bin/import_data.rb providers` |
| Clear mode (авто-откат БД после Route) | только в рамках текущей сессии меню, не сохраняется между запусками | Меню → **Clear mode** (toggle) |

## Структура базы данных

### 1. operations_queue
Очередь операций, ожидающих обработки.

| Поле | Тип | Описание |
|------|-----|----------|
| operation_id | String | Уникальный идентификатор операции (PK) |
| created_at | DateTime | Время создания операции |
| amount | Integer | Сумма операции (в рублях) |
| bank | String | Банк получателя |
| card_brand | String | Бренд карты |
| payout_requisite_sbp_phone | String | Номер телефона |
| payout_requisite_bank_name | String | Название банка |

### 2. providers
Справочник провайдеров платежных систем.

| Поле | Тип | Описание |
|------|-----|----------|
| payment_system_id | Integer | PK, autoincrement |
| payment_system | String | Название платёжной системы (unique) |
| status | String | Статус |
| traffic_percentage | Integer | Целевая доля по количеству заявок |
| priority | Integer | Приоритет в каскаде |
| limit_amount_min / limit_amount_max | Integer | Диапазон суммы чека (hard-constraint) |
| daily_amount_limit / daily_approved_amount | Integer | Дневной лимит по сумме / текущий оборот |
| in_progress_count_limit / in_progress_count | Integer | Лимит и текущее число заявок в обработке |
| in_progress_amount_limit / in_progress_amount | Integer | Лимит и текущая сумма заявок в обработке |
| available_requisites | Integer | Доступное количество реквизитов |
| conversion_24h | Float | Конверсия за 24 часа |
| avg_latency_sec | Integer | Средняя задержка |
| banks | String | Список поддерживаемых банков, JSON-массив (например `["sberbank","tinkoff"]`); `[]` - без ограничений |
| exclude_banks | Boolean | Исключать (blacklist) или включать (whitelist) банки из `banks` |
| provider_margin_pct / merchant_margin_pct | Float | Маржа провайдера / мерчанта |
| allow_negative_agreement | Boolean | Разрешить провайдеру маржу выше мерчантской |
| note | String | Примечание |
| volume_share_pct | Float | Целевая доля по объёму (soft-goal) |
| requests_per_minute_limit | Float | Rate limit (заявок/мин) |
| daily_turnover_min / daily_turnover_max | Integer | Мин./макс. дневной оборот (фин. обязательства) |
| preferred_range_min / preferred_range_max | Integer | Приоритетный диапазон суммы для стратегии "по сумме чека" (soft-goal, не путать с limit_amount_min/max) |
| daily_approved_date | String | Дата (UTC-со-сдвигом провайдера), на которую актуален `daily_approved_amount` - основа для сброса дневных счётчиков при смене суток |
| daily_utc_offset | Integer | Часовой сдвиг (в секундах) для вычисления «календарного дня» провайдера |

`volume_share_pct`, `requests_per_minute_limit`, `daily_turnover_min/max`, `preferred_range_min/max` не приходят из `data/providers.json` - `ProvidersImporter` их не трогает; значения для рейтингуемых провайдеров приходят из `config/business_parameters.yml` через `BusinessParametersImporter` (шаг `business_parameters` в `bin/import_data.rb`, и заново - автоматически в начале каждого запуска `bin/route.rb`/при открытии Provider metrics в меню, так что правка YAML подхватывается без отдельного реимпорта).

`daily_approved_date`/`daily_utc_offset` и колонки `explanation`/`details`/`dispatched_at` ниже добавляются в уже существующую БД автоматически, аддитивно (`Db.upgrade_schema!`, не теряя данные) — пересоздавать файл БД для их появления не нужно.

### 3. operations_history
История выполненных операций (источник для актуалов рейтинга - см. `HistoricalActualsProvider`).

| Поле | Тип | Описание |
|------|-----|----------|
| operation_id | String | Уникальный идентификатор операции (PK) |
| created_at | DateTime | Время создания операции |
| amount | Integer | Сумма операции |
| bank | String | Банк получателя |
| card_brand | String | Бренд карты |
| payment_system_id | Integer | FK → providers |
| status | String | approved / rejected / expired |
| latency_sec | Integer | Время обработки |

### 4. routing_decisions
Итоговое решение роутинга по операции.

| Поле | Тип | Описание |
|------|-----|----------|
| operation_id | String | PK, FK → operations_queue |
| selected_payment_system_id | Integer | FK → providers |
| simulated_result | String | approved / rejected / expired |
| latency_sec | Integer | |
| created_at | DateTime | |
| explanation | String (JSON) | Полная трассировка решения — причины по каждому провайдеру, активные стратегии, веса, разбивка рейтинга; необязательное поле сверх формата ТЗ, используется отчётом |

### 5. routing_attempts
Попытки провайдеров в рамках одного решения (для объяснимости).

| Поле | Тип | Описание |
|------|-----|----------|
| attempt_id | Integer | PK, autoincrement |
| operation_id | String | FK → routing_decisions |
| payment_system_id | Integer | FK → providers |
| attempt_number | Integer | Порядковый номер попытки |
| decision | String | selected / skipped |
| reason | String | |
| details | String (JSON) | Подробности попытки (все причины hard-constraints, детали ранжирования и т.д.) |
| dispatched_at | DateTime | Момент фактического обращения к провайдеру (для скользящего RPM-окна) |
| created_at | DateTime | |

### 6. eligible_providers
Провайдеры, прошедшие (или нет) hard-constraints для операции.

| Поле | Тип | Описание |
|------|-----|----------|
| operation_id | String | FK → operations_queue (составной PK с payment_system_id) |
| payment_system_id | Integer | FK → providers |
| is_eligible | Boolean | |
| checked_at | DateTime | |

### 7. provider_skip_reasons
Причины исключения провайдера для операции.

| Поле | Тип | Описание |
|------|-----|----------|
| skip_reason_id | Integer | PK, autoincrement |
| operation_id | String | FK → operations_queue |
| payment_system_id | Integer | FK → providers |
| reason | String | |
| created_at | DateTime | |
