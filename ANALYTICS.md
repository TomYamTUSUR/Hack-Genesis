# Аналитический контур роутинга

Аналитика и журналирование работают с SQLite-базой `DB/operations.db`. Каталоги `data/` и `scripts/` используются только для чтения и никогда не изменяются.

## Первичная загрузка

```powershell
bundle exec ruby bin/import_sources.rb
```

Команда транзакционно переносит исходные `providers.json`, `operations_history.csv`, очередь и эталонные решения в существующую схему БД. Повторный запуск безопасен: записи обновляются по их ключам, а уже обработанные операции не возвращаются в очередь.

Для других файлов можно передать `--providers`, `--history`, `--queue`, `--references` и `--database`.

## Отчёт

```powershell
bundle exec ruby bin/analyze.rb
```

По умолчанию команда только читает `DB/operations.db` и записывает результат в `reports/routing_report.json`. Другой файл БД задаётся через `--database`; `--stdout` выводит JSON без создания отчёта.

Отчёт содержит распределение количества и объёма операций, статусы, latency, загрузку лимитов, причины пропуска, очередь, рекомендации и проверки качества данных.

## Запись новых результатов

```powershell
bundle exec ruby bin/log_operations.rb `
  --operations incoming/operations_queue.json `
  --decisions incoming/routing_decisions.json
```

Запись выполняется одной транзакцией. Обновляются `operations_history`, `routing_decisions`, `routing_attempts`, `eligible_providers` и `provider_skip_reasons`; завершённые операции удаляются из `operations_queue`. Для каждого `operation_id` хранится актуальное состояние решения.

## Проверка

```powershell
bundle install
bundle exec ruby -Ilib test/routing_analytics_test.rb
ruby scripts/validate_10.rb data/sample_routing_decisions.json
```

Аналитическое чтение открывает SQLite в режиме read-only. Вывод внутрь `data/` и `scripts/` дополнительно блокируется программно.
