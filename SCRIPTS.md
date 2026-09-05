# Описание скриптов проекта

В документе описаны Ruby-файлы аналитического/БД-контура: команды для работы с базой данных, валидатор, библиотеки и тесты. Блок стратегий и рейтинга (`lib/payment_routing/`) описан отдельно в `README.md`.

Примеры команд выполняются из корня проекта. Для установки зависимостей из `Gemfile` используется `bundle install`. Команды из `bin/` поддерживают `--help`; пути по умолчанию вычисляются относительно проекта, а переданные относительные пути — относительно текущего рабочего каталога.

## Создание базы данных

### `db/create_tables.rb`

Тонкая обёртка над `db/database.rb` (`PaymentRouting::Db.connect` + `PaymentRouting::Db.create_schema!`) — единственное место, где описана схема, чтобы реальная БД и in-memory БД в тестах никогда не расходились. Создаёт SQLite-файл `db/operations.db`, если его ещё нет, и восемь таблиц:

- `providers` — провайдеры, их ограничения и метрики;
- `operations_queue` — очередь заявок и реквизиты;
- `operations_history` — история операций;
- `routing_decisions` — выбранные провайдеры и результаты;
- `routing_attempts` — последовательность попыток;
- `eligible_providers` — допустимость провайдеров для заявки;
- `provider_skip_reasons` — причины пропуска провайдеров;
- `reference_decisions` — эталонные решения (для `scripts/validate_10.rb`, БД её не заполняет).

Включает внешние ключи (`PRAGMA foreign_keys = ON`) и выводит список таблиц. Использует `CREATE TABLE IF NOT EXISTS`: существующие таблицы и данные сохраняются, но структура уже созданных таблиц не обновляется. Исходные JSON и CSV этот скрипт не загружает. Аргументов командной строки нет.

```powershell
bundle exec ruby db/create_tables.rb
```

## Импорт и запись данных

### `bin/import_data.rb`

Загружает `data/providers.json`, `data/operations_history.csv` и `data/operations_queue_10.json` в БД через `PaymentRouting::Importers::{ProvidersImporter,OperationsQueueImporter,OperationsHistoryImporter}` (Sequel). Создаёт схему сам, если её ещё нет. `data/reference_decisions.json` не импортирует — это эталон для `scripts/validate_10.rb`, а не рабочие данные.

Insert-or-update по естественному ключу (`payment_system`/`operation_id`) — повторный запуск обновляет существующие строки, а не плодит дубликаты. `providers` должен импортироваться раньше `history` (нужен `payment_system_id`) — при запуске без аргументов порядок соблюдается автоматически.

Параметры — позиционные имена источников: `providers`, `queue`, `history` (без аргументов — все три по порядку).

```powershell
bundle exec ruby bin/import_data.rb
bundle exec ruby bin/import_data.rb providers history
```

### `bin/log_operations.rb`

Сохраняет уже рассчитанные результаты роутинга через `RoutingAnalytics::DatabaseWriter#log_operations`. Получает JSON с операциями в формате очереди и JSON с решениями в формате примера результата. Проверяет отсутствие повторных `operation_id` и совпадение наборов операций и решений.

Одной транзакцией обновляет историю и решения, заменяет попытки, признаки допустимости и причины пропуска для каждой операции. Строку в `operations_queue` **не удаляет** — на неё ссылаются `routing_decisions`/`eligible_providers`/`provider_skip_reasons` внешними ключами, удаление сломало бы эти связи; "обработанность" операции `Analyzer` определяет наличием записи в `operations_history`/`routing_decisions`, а не отсутствием в очереди. Повторная запись для того же `operation_id` заменяет его текущее состояние. Выбор провайдера и симуляцию выплаты скрипт не выполняет — ожидает уже готовое решение.

Обязательные параметры: `--operations PATH`, `--decisions PATH`. Необязательный: `--database PATH`, по умолчанию `db/operations.db`. Операция должна уже существовать в `operations_queue` (иначе внешний ключ `routing_decisions.operation_id` не даст записать решение).

```powershell
bundle exec ruby bin/log_operations.rb --database path/to/operations.db --operations incoming/operations_queue.json --decisions incoming/routing_decisions.json
```

## Статистика и отчёты

### `bin/update_provider_minute_stats.rb`

Пересчитывает показатели каждого провайдера по `operations_history` за интервал **(момент расчёта − 60 секунд, момент расчёта]**. Учитывает часовые пояса и все статусы операций. Подробности формул и периодов — в `PROVIDER_MINUTE_STATS.md`.

Записывает в `providers` только `conversion_24h` и `avg_latency_sec` (калибровка по факту); `requests_last_minute` — только если колонка уже добавлена вручную. **Не пишет** `in_progress_count`/`in_progress_amount` — в этом проекте они означают одновременно обрабатываемые заявки (см. `PaymentRouting::Rating::LoadFactorCalculator`), а не поток заявок за минуту; минутный поток остаётся только в JSON-отчёте (`requests_last_minute`, `periods.minute`). Никогда не меняет схему. Это разовый пересчёт, а не постоянно работающий процесс.

Параметры: `--database PATH` (по умолчанию `db/operations.db`), `--at ISO8601` (по умолчанию текущее время, обязателен `Z` или сдвиг UTC), `--dry-run` (только чтение, ничего не пишет).

```powershell
bundle exec ruby bin/update_provider_minute_stats.rb --at 2026-07-29T08:01:00+03:00
```

### `bin/analyze_db.rb`

Формирует аналитический JSON по канонической схеме из восьми таблиц. Использует `RoutingAnalytics::CanonicalDatabaseAnalytics`: строго проверяет точный набор таблиц, порядок и названия колонок, а также внешние ключи (`CanonicalDatabaseSource::TABLE_COLUMNS`/`EXPECTED_FOREIGN_KEYS`) — любое расхождение со схемой `db/database.rb` (лишняя/отсутствующая колонка, другой FK) останавливает отчёт с понятной ошибкой вместо тихого искажения цифр. Читает базу только на чтение и по умолчанию сохраняет `reports/routing_report_db.json`.

Для расчётов использует общий `RoutingAnalytics::Analyzer`. Объединяет причины пропуска из `provider_skip_reasons` и пропущенных `routing_attempts`, исключая дубли по операции, провайдеру и причине. Метаданные снимка, шлюза и мерчанта (`snapshot_at`/`gateway`/`merchant`) всегда `null` — для них нет колонок в канонической схеме.

Параметры: `--database PATH` (по умолчанию `db/operations.db`), `--output PATH`, `--stdout`. Запись отчёта внутрь `data/`, `scripts/` и `db/` запрещена кодом (`PathGuard`).

```powershell
bundle exec ruby bin/analyze_db.rb
bundle exec ruby bin/analyze_db.rb --stdout
```

## Проверка решений

### `scripts/validate_10.rb`

Проверяет переданный JSON с решениями для десяти заявок из `data/operations_queue_10.json`. Также читает `data/providers.json` и `data/reference_decisions.json` напрямую (без БД).

Проверяет обязательные поля решения и попыток, покрытие очереди, детерминированные случаи и допустимость выбранного провайдера по текущему снимку: статус, долю трафика, диапазон суммы, дневной лимит, ограничения in-progress, реквизиты, маржу и банки. Для известных случаев проверяет наличие попытки со статусом `skipped`; точное совпадение текста причины с эталоном не проверяет.

Печатает результаты, ошибки и предупреждения. Возвращает код `0`, если ошибок нет, иначе `1`; одни предупреждения не означают провал. Файлы не меняет.

Ограничения: не обновляет состояние провайдеров последовательно между заявками, не проверяет минутный лимит запросов и не оценивает качество стратегий. Поэтому успешная проверка не доказывает выполнение всего ТЗ.

Единственный обязательный аргумент — путь к JSON с решениями:

```powershell
ruby scripts/validate_10.rb path/to/routing_decisions.json
```

## Библиотеки

Эти файлы подключаются через `require_relative`; самостоятельного интерфейса командной строки у них нет.

### `lib/routing_analytics.rb`

Основная библиотека аналитики и журналирования. Содержит:

- `Loader` — чтение JSON, используемых `bin/log_operations.rb` (провайдеров/историю/очередь для роутинга загружает `PaymentRouting::Importers`, не этот класс);
- `DatabaseSource` — read-only чтение канонической схемы и подготовку данных для `Analyzer` (более мягкая проверка, чем `CanonicalDatabaseSource` — только наличие таблиц, без строгой сверки колонок/FK);
- `DatabaseWriter` — запись результатов роутинга (`log_operations`) в уже засеянную БД;
- `Analyzer` — объединение истории и актуальных решений без двойного подсчёта операций, расчёт распределений, конверсии, задержек, лимитов, очереди, рекомендаций и качества данных;
- `ReportWriter` — атомарное сохранение JSON-отчёта;
- `PathGuard`, `Utils`, `Error` — защиту путей записи, вспомогательные вычисления и ошибки.

Используется `bin/log_operations.rb` и библиотекой канонической аналитики. Не реализует самостоятельный маршрутизатор выплат.

### `lib/canonical_database_analytics.rb`

Адаптирует каноническую схему из восьми таблиц к общему аналитическому движку. `CanonicalDatabaseSource` строго проверяет схему (точный набор таблиц, порядок и названия колонок, внешние ключи), читает провайдеров, историю, очередь, решения и попытки, объединяет причины пропуска, проверяет целостность и отсутствующие связанные записи. `CanonicalDatabaseAnalytics` передаёт данные в общий `Analyzer` и дополняет отчёт подсчётом причин пропуска.

Используется `bin/analyze_db.rb`. Работает только на чтение, не создаёт и не мигрирует таблицы.

## Тесты

Все три файла используют Minitest и строят собственную временную БД через `PaymentRouting::Db`/`PaymentRouting::Importers` (не зависят от заранее подготовленного файла) — см. также `rake test`, который запускает их вместе с тестами блока рейтинга/стратегий.

| Файл | Что проверяет |
| --- | --- |
| `test/provider_minute_stats_test.rb` | Границы минутного окна, часовые пояса, учёт всех статусов, нулевые значения, повторный пересчёт, сброс устаревшей статистики, некорректные даты и суммы, откат значений и новой колонки при ошибке записи, запуск CLI из другого каталога, совместимость с `CanonicalDatabaseSource` после пересчёта. |
| `test/canonical_database_analytics_test.rb` | Ожидаемые показатели отчёта на свежесобранной БД, сохранение её хеша при чтении, корректный JSON и отклонение несовместимой схемы. |
| `test/routing_analytics_test.rb` | Расчёты отчёта на реальных `data/*`, запись решения через `DatabaseWriter#log_operations` и замену решения при повторном журналировании, чтение без изменения БД, запись JSON и запрет записи в защищённые каталоги. |

Запуск:

```powershell
rake test
```

## Совместимость команд

Все команды работают на одной и той же канонической схеме (`db/create_tables.rb` / `db/database.rb`): `bin/import_data.rb` → `bin/log_operations.rb` / `bin/update_provider_minute_stats.rb` → `bin/analyze_db.rb`. Отдельного варианта схемы для аналитики больше нет — `analytics_metadata` и связанные с ней `bin/import_sources.rb`/`bin/analyze.rb` убраны как дублирующие `bin/import_data.rb`/`bin/analyze_db.rb`.
