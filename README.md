Тут живет аналитик
Я считаю бд лишней на данном этапе 
2+2 = 22

Аналитика маршрутизации
Модуль анализирует распределение операций между провайдерами, статусы обработки, суммы, задержки, загрузку лимитов и причины пропуска провайдеров.
Запуск
ruby bin/analyze.rb
По умолчанию используются:
- data/providers.json — состояние и лимиты провайдеров;
- data/operations_history.csv — завершённые операции;
- data/operations_queue_10.json — необработанная очередь;
- logs/routing_operations.jsonl — журнал новых операций, если существует.
Отчёт сохраняется в:
reports/routing_report.json
Обновление данных
Для записи новых операций и решений:
ruby bin/log_operations.rb `
  --operations queue.json `
  --decisions decisions.json
После этого повторно запустите bin/analyze.rb. Для каждого operation_id учитывается последняя запись журнала.
Проверка
ruby -Ilib test/routing_analytics_test.rb
ruby scripts/validate_10.rb data/sample_routing_decisions.json

А тут подробнее 

# Аналитический контур роутинга

Этот этап проекта занимается только аналитикой и журналированием операций. Он не выбирает провайдера и не изменяет состояние исходных файлов.

## Неизменяемые источники

Каталоги `data/` и `scripts/` используются только для чтения. Аналитика сохраняет отчёты в `reports/`, а журнал новых операций — в `logs/`.
CLI дополнительно блокирует любой путь вывода внутри `data/` или `scripts/`, включая вложенные каталоги.

Поддерживаются исходные структуры:

- provider snapshot: объект `providers.json` с массивом `providers`;
- history: строки `operations_history.csv` без переименования колонок;
- operation: объект из очереди `operations_queue_10.json`;
- routing decision: объект из `sample_routing_decisions.json`.

## Что считается

Основные показатели:

- количество и сумма всех уникальных операций;
- отдельный срез ещё не обработанной очереди: количество, сумма, диапазон чеков и банки;
- count share и volume share по провайдерам;
- распределение отдельно по каждому календарному дню, чтобы новые дни не смешивали текущую картину со старой;
- отклонение count share от `traffic_percentage`;
- approved, rejected, expired и approval rate;
- средняя, p50 и p95 latency;
- загрузка daily- и in-progress-лимитов из актуального provider snapshot;
- причины `skipped` из `attempts` новых решений;
- предупреждения о качестве и полноте данных;
- конкретные рекомендации по целевым долям, ёмкости и expired.

`approval_rate_pct` рассчитывается как `approved / все операции провайдера`. Он намеренно не называется `conversion_24h`: точное определение исходного поля `conversion_24h` в данных не задано, поэтому эти показатели хранятся отдельно.

Рекомендации строятся по последнему календарному дню в завершённых операциях. Общие показатели за весь доступный период и дневные срезы сохраняются одновременно.

Исторические операции используются для аналитики фактического распределения. Они не проверяются повторно по текущим банковским ограничениям provider snapshot, поскольку snapshot относится к другому моменту времени.

## Предварительный отчёт

```powershell
ruby bin/analyze.rb
```

По умолчанию команда читает:

- `data/providers.json`;
- `data/operations_history.csv`;
- `data/operations_queue_10.json`;
- `logs/routing_operations.jsonl`, если журнал уже существует.

Результат записывается в `reports/routing_report.json`. Чтобы только вывести JSON в stdout:

```powershell
ruby bin/analyze.rb --stdout
```

Можно передать новые файлы в тех же структурах, не заменяя исходники:

```powershell
ruby bin/analyze.rb `
  --providers incoming/providers.json `
  --history incoming/operations_history.csv `
  --queue incoming/operations_queue.json `
  --journal logs/routing_operations.jsonl `
  --output reports/routing_report.json
```

Каждый запуск заново читает переданные provider snapshot, history и journal. Поэтому отчёт обновляется при появлении новых данных без изменения основной логики.

## Журналирование новых операций

После получения решений для очереди:

```powershell
ruby bin/log_operations.rb `
  --operations incoming/operations_queue.json `
  --decisions incoming/routing_decisions.json
```

Для каждой операции в `logs/routing_operations.jsonl` добавляется отдельное событие:

```json
{
  "logged_at": "2026-07-30T10:00:00+03:00",
  "event": "routing_operation",
  "operation_id": "op_111",
  "operation": {},
  "routing_decision": {}
}
```

Вложенные `operation` и `routing_decision` сохраняют исходную структуру. Поле `phone` и возможные карточные реквизиты заменяются на `[REDACTED]` до записи в журнал.

Журнал append-only и сохраняет повторные события для аудита. При построении аналитики для каждого `operation_id` берётся последнее событие; если новый journal содержит ID из history, journal имеет приоритет.

## Проверка

```powershell
ruby -Ilib test/routing_analytics_test.rb
```

Тесты проверяют базовые агрегаты исходной истории, маскирование реквизитов, обработку повторного события и запись валидного JSON-отчёта.

