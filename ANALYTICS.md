# Аналитический контур роутинга

Аналитика и журналирование работают с SQLite-базой `db/operations.db` (схема — `db/database.rb`/`db/create_tables.rb`). Каталоги `data/` и `scripts/` используются только для чтения и никогда не изменяются.

## Первичная загрузка

```powershell
bundle exec ruby bin/import_data.rb
```

Переносит `data/providers.json`, `data/operations_history.csv` и `data/operations_queue_10.json` в БД (см. `lib/payment_routing/importers`). Повторный запуск безопасен: записи обновляются по их ключам. Можно импортировать по частям: `bundle exec ruby bin/import_data.rb providers history`.

`data/reference_decisions.json` в БД не заносится - это эталон для самопроверки (`scripts/validate_10.rb`), а не часть рабочих данных роутинга.

## Отчёт

```powershell
bundle exec ruby bin/analyze_db.rb
```

Читает `db/operations.db` через `CanonicalDatabaseAnalytics` (строгая проверка соответствия схемы - таблицы, колонки, внешние ключи) и пишет `reports/routing_report_db.json`. `--stdout` выводит JSON без создания файла; `--database PATH`/`--output PATH` переопределяют пути по умолчанию.

Отчёт содержит распределение количества и объёма операций, статусы, latency, загрузку лимитов, причины пропуска, очередь, рекомендации и проверки качества данных.

## Запись новых результатов

```powershell
bundle exec ruby bin/log_operations.rb `
  --operations incoming/operations_queue.json `
  --decisions incoming/routing_decisions.json
```

Запись выполняется одной транзакцией: обновляются `operations_history`, `routing_decisions`, `routing_attempts`, `eligible_providers` и `provider_skip_reasons`. Строка в `operations_queue` не удаляется (на неё ссылаются `routing_decisions`/`eligible_providers`/`provider_skip_reasons` внешними ключами) - "обработанность" операции `Analyzer` определяет наличием записи в `operations_history`/`routing_decisions`, а не отсутствием в очереди. Повторный вызов для того же `operation_id` заменяет его решение и попытки.

## Проверка

```powershell
bundle install
rake test
ruby scripts/validate_10.rb path/to/routing_decisions.json
```

Аналитическое чтение открывает SQLite в режиме read-only. Запись внутрь `data/` и `scripts/` дополнительно блокируется программно (`RoutingAnalytics::PathGuard`).
