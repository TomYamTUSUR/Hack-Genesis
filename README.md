# Operations Database Schema

База данных для управления операциями выплат через СБП (Система быстрых платежей) с маршрутизацией через провайдеров.

## Описание

Проект содержит схему базы данных для хранения:
- Очереди операций на выплату
- Информации о провайдерах платежных систем
- Истории выполненных операций

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
| payment_system | String | Название платежной системы (PK) |
| status | String | Статус |
| traffic_percentage | Integer | Процент трафика |
| priority | Integer | Приоритет |
| limit_amount_min | Integer | Минимальная сумма операции |
| limit_amount_max | Integer | Максимальная сумма операции |
| daily_amount_limit | Integer | Дневной лимит по сумме |
| daily_approved_amount | Integer | Одобренная сумма за день |
| in_progress_count_limit | Integer | Лимит операций в обработке |
| in_progress_count | Integer | Текущее количество в обработке |
| in_progress_amount_limit | Integer | Лимит суммы в обработке |
| in_progress_amount | Integer | Текущая сумма в обработке |
| available_requisites | Integer | Доступное количество реквизитов |
| conversion_24h | Float | Конверсия за 24 часа |
| avg_latency_sec | Integer | Средняя задержка |
| banks | String | Список поддерживаемых банков, JSON-массив (например `["sberbank","tinkoff"]`); `[]` - без ограничений |
| exclude_banks | Boolean | Исключать или включать банки |
| provider_margin_pct | Float | Маржа провайдера |
| merchant_margin_pct | Float | Маржа мерчанта |
| allow_negative_agreement | Boolean | Разрешить отрицательный баланс |
| note | String | Примечание |
| volume_share_pct | Float | Доля объема операций |
| requests_per_minute_limit | Float | Лимит запросов в минуту |
| daily_turnover_min | Integer | Минимальный дневной оборот |
| daily_turnover_max | Integer | Максимальный дневной оборот |

### 3. operations_history
История выполненных операций.

| Поле | Тип | Описание |
|------|-----|----------|
| operation_id | String | Уникальный идентификатор операции (PK) |
| created_at | DateTime | Время создания операции |
| amount | Integer | Сумма операции |
| bank | String | Банк получателя |
| card_brand | String | Бренд карты |
| payment_system | String | Использованная платежная система |
| status | String | Статус |
| latency_sec | Integer | Время обработки |

## Установка

### Требования
- Ruby 2.7 или выше
- Bundler (`gem install bundler`)

### Шаги установки

1. Установите зависимости проекта:

bundle install

2. Создайте базу данных:

bundle exec ruby db/create_tables.rb

3. Проверьте создание таблиц (файл появится в db/operations.db):

sqlite3 db/operations.db ".tables"