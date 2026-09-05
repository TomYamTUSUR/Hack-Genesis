# Умный роутинг выплат

Механизм распределения выплат между провайдерами (СБП): блок стратегий и рейтинга на Ruby + БД (SQLite/Sequel) для хранения провайдеров, очереди операций, истории и результатов роутинга.

## Структура проекта

- `lib/payment_routing/` — доменная логика: провайдеры/операции, блок hard-constraints (`hard_filter/`), блок стратегий (`strategies/`), блок рейтинга (`rating/`), оркестратор (`router/` — hard-constraints → рейтинг → попытки с fallback → обновление рантайм-состояния между операциями → запись состояния обратно в БД), загрузчики из БД (`ProviderRegistry`, `HistoricalActualsProvider`, `OperationQueueLoader`, `DecisionsReader`), импортёры `data/*`/`config/business_parameters.yml → БД` (`importers/`).
- `db/` — схема SQLite (`database.rb`) и скрипт её создания (`create_tables.rb`).
- `config/` — `routing.yml` (пути к данным для импорта, список рейтингуемых провайдеров, `active_strategies`, `fallback_provider`), `strategies.yml` (коэффициенты стратегий), `business_parameters.yml` (регулируемые бизнес-величины по провайдерам — `preferred_range_min/max`, `volume_share_pct`, `requests_per_minute_limit`, `daily_turnover_min/max` — которых нет в `data/providers.json`; временный источник, см. комментарий в файле).
- `data/` — исходные файлы для первичного импорта в БД (`providers.json`, `operations_history.csv`, `operations_queue_10.json`).
- `bin/` — исполняемые скрипты: `import_data.rb` (импорт `data/*` + `config/business_parameters.yml` в БД), `route.rb` (обрабатывает очередь через Router → запись решений и обновлённого состояния провайдеров в БД; сам JSON не пишет), `build_decisions.rb` (собирает обязательный `routing_decisions_test.json` из БД после `route.rb`), `build_report.rb` (собирает обязательный `routing_report_test.json` из БД после `route.rb`), `demo_rating.rb` (демонстрация рейтинга на нескольких стратегиях), `demo_hard_filter.rb` (демонстрация hard-constraints на синтетических данных, БД не требует), `analyze_db.rb`/`log_operations.rb`/`update_provider_minute_stats.rb` (аналитика, см. `SCRIPTS.md`).
- `test/` — Minitest, зеркалирует структуру `lib/`.

Рейтинг, стратегии и hard-constraints читают только БД (`db/operations.db`) — файлы в `data/`/`config/business_parameters.yml` участвуют один раз, на этапе импорта. `routing_decisions_test.json`/`routing_report_test.json` — обязательные артефакты по итогам обработки `data/operations_queue_10.json` (или другой очереди, импортированной в БД); оба всегда собираются из БД (`bin/build_decisions.rb`/`bin/build_report.rb`), а не из решений `Router`'а в памяти — `bin/route.rb` только считает и журналирует в БД.

Внутри одного прогона `bin/route.rb` рантайм-состояние провайдеров (`in_progress_count/amount`, `daily_approved_amount`, `count_share_actual`/`volume_share_actual`/`turnover_actual`) пересчитывается `Router::MetricsUpdater` после каждой операции — так следующая операция очереди видит уже изменившуюся картину, а не статичный снимок на начало прогона; доли (`count_share_actual`/`volume_share_actual`) пересчитываются сразу у всех рейтингуемых провайдеров, а не только у выбранного, так как это доли от общего количества/объёма. По завершении прогона `Router::StateWriter` пишет изменившиеся `in_progress_count/amount`/`daily_approved_amount` обратно в таблицу `providers` — иначе следующий запуск `bin/route.rb` стартовал бы заново с исходных значений `data/providers.json`. Симуляция исхода (`OutcomeSimulator`) в v1 всегда возвращает `"approved"` — реальная модель (например, на основе `conversion_24h`) не входит в текущий объём.

## Установка и запуск

### Требования
- Ruby (проверено на 4.0)
- Bundler (`gem install bundler`)

### Шаги

```
bundle install                          # зависимости (sequel, sqlite3, rake, minitest, csv)
bundle exec ruby db/create_tables.rb    # создать схему в db/operations.db
bundle exec ruby bin/import_data.rb     # загрузить data/* + business_parameters.yml в БД (провайдеры - до history)
bundle exec ruby bin/demo_rating.rb     # прогнать несколько стратегий и посмотреть ранжирование
bundle exec ruby bin/demo_hard_filter.rb # прогнать hard-constraints по каждому правилу (без БД)
bundle exec ruby bin/route.rb           # обработать очередь, записать решения и состояние провайдеров в БД
bundle exec ruby bin/build_decisions.rb # собрать routing_decisions_test.json из БД
bundle exec ruby bin/build_report.rb    # собрать routing_report_test.json из БД
bundle exec rake test                   # тесты (или просто `rake test`, без bundler)
```

Импорт можно делать по частям: `bundle exec ruby bin/import_data.rb providers history`.

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

`volume_share_pct`, `requests_per_minute_limit`, `daily_turnover_min/max`, `preferred_range_min/max` не приходят из `data/providers.json` - `ProvidersImporter` их не трогает; значения для рейтингуемых провайдеров приходят из `config/business_parameters.yml` через отдельный `BusinessParametersImporter` (шаг `business_parameters` в `bin/import_data.rb`).

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

### 8. reference_decisions
Эталонные решения для самопроверки (единственный допустимый провайдер по детерминированным кейсам).

| Поле | Тип | Описание |
|------|-----|----------|
| operation_id | String | PK, FK → operations_queue |
| required_payment_system_id | Integer | FK → providers |
| reason | Text | |
