# frozen_string_literal: true

require 'sqlite3'

database_path = File.expand_path('operations.db', __dir__)
database = SQLite3::Database.new(database_path)
database.execute('PRAGMA foreign_keys = ON')

database.execute_batch(<<~SQL)
  CREATE TABLE IF NOT EXISTS operations_queue (
    operation_id varchar PRIMARY KEY NOT NULL,
    created_at datetime,
    amount int,
    bank varchar,
    card_brand varchar,
    payout_requisite_sbp_phone varchar,
    payout_requisite_bank_name varchar
  );

  CREATE TABLE IF NOT EXISTS providers (
    payment_system_id INTEGER PRIMARY KEY AUTOINCREMENT,
    payment_system varchar UNIQUE NOT NULL,
    status varchar,
    traffic_percentage int,
    priority int,
    limit_amount_min int,
    limit_amount_max int,
    daily_amount_limit int,
    daily_approved_amount int,
    in_progress_count_limit int,
    in_progress_count int,
    in_progress_amount_limit int,
    in_progress_amount int,
    available_requisites int,
    conversion_24h float,
    avg_latency_sec int,
    banks varchar,
    exclude_banks boolean,
    provider_margin_pct float,
    merchant_margin_pct float,
    allow_negative_agreement boolean,
    note varchar,
    volume_share_pct float,
    requests_per_minute_limit float,
    daily_turnover_min int,
    daily_turnover_max int
  );

  CREATE TABLE IF NOT EXISTS operations_history (
    operation_id varchar PRIMARY KEY NOT NULL,
    created_at datetime,
    amount int,
    bank varchar,
    card_brand varchar,
    payment_system_id int,
    status varchar,
    latency_sec int,
    FOREIGN KEY (payment_system_id) REFERENCES providers (payment_system_id)
  );

  CREATE TABLE IF NOT EXISTS routing_decisions (
    operation_id varchar PRIMARY KEY NOT NULL,
    selected_payment_system_id int,
    simulated_result varchar,
    latency_sec int,
    created_at datetime,
    FOREIGN KEY (operation_id) REFERENCES operations_queue (operation_id),
    FOREIGN KEY (selected_payment_system_id) REFERENCES providers (payment_system_id)
  );

  CREATE TABLE IF NOT EXISTS routing_attempts (
    attempt_id INTEGER PRIMARY KEY AUTOINCREMENT,
    operation_id varchar,
    payment_system_id int,
    attempt_number int,
    decision varchar,
    reason varchar,
    created_at datetime,
    UNIQUE (operation_id, payment_system_id),
    UNIQUE (operation_id, attempt_number),
    FOREIGN KEY (operation_id) REFERENCES routing_decisions (operation_id),
    FOREIGN KEY (payment_system_id) REFERENCES providers (payment_system_id)
  );

  CREATE TABLE IF NOT EXISTS eligible_providers (
    operation_id varchar NOT NULL,
    payment_system_id int NOT NULL,
    is_eligible boolean,
    checked_at datetime,
    PRIMARY KEY (operation_id, payment_system_id),
    FOREIGN KEY (operation_id) REFERENCES operations_queue (operation_id),
    FOREIGN KEY (payment_system_id) REFERENCES providers (payment_system_id)
  );

  CREATE TABLE IF NOT EXISTS provider_skip_reasons (
    skip_reason_id INTEGER PRIMARY KEY AUTOINCREMENT,
    operation_id varchar,
    payment_system_id int,
    reason varchar,
    created_at datetime,
    UNIQUE (operation_id, payment_system_id, reason),
    FOREIGN KEY (operation_id) REFERENCES operations_queue (operation_id),
    FOREIGN KEY (payment_system_id) REFERENCES providers (payment_system_id)
  );

  CREATE TABLE IF NOT EXISTS reference_decisions (
    operation_id varchar PRIMARY KEY NOT NULL,
    required_payment_system_id int,
    reason text,
    FOREIGN KEY (operation_id) REFERENCES operations_queue (operation_id),
    FOREIGN KEY (required_payment_system_id) REFERENCES providers (payment_system_id)
  );
SQL

tables = database.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
puts 'OK'
puts "Созданные таблицы: #{tables.flatten.join(', ')}"
database.close
