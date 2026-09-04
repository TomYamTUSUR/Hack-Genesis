require 'sequel'

DB = Sequel.connect('sqlite://operations.db')

# Таблица operations_queue
DB.create_table? :operations_queue do
  String :operation_id, primary_key: true
  DateTime :created_at, null: false
  Integer :amount, null: false
  String :bank, null: false
  String :card_brand
  String :payout_requisite_sbp_phone
  String :payout_requisite_bank_name
end

# Таблица providers
DB.create_table? :providers do
  String :payment_system, primary_key: true
  String :status, null: false, default: 'active'
  Integer :traffic_percentage, null: false
  Integer :priority, null: false
  Integer :limit_amount_min
  Integer :limit_amount_max
  Integer :daily_amount_limit
  Integer :daily_approved_amount
  Integer :in_progress_count_limit
  Integer :in_progress_count
  Integer :in_progress_amount_limit
  Integer :in_progress_amount
  Integer :available_requisites
  Float :conversion_24h
  Integer :avg_latency_sec
  String :banks
  TrueClass :exclude_banks, default: false
  Float :provider_margin_pct
  Float :merchant_margin_pct
  TrueClass :allow_negative_agreement, default: false
  String :note
  
  # Дополнительные поля
  Float :volume_share_pct
  Float :requests_per_minute_limit
  Integer :daily_turnover_min
  Integer :daily_turnover_max
end

# Таблица operations_history
DB.create_table? :operations_history do
  String :operation_id, primary_key: true
  DateTime :created_at, null: false
  Integer :amount, null: false
  String :bank, null: false
  String :card_brand
  String :payment_system, null: false
  String :status, null: false
  Integer :latency_sec
end

puts "OK"