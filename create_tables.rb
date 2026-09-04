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
  primary_key :payment_system_id
  String :payment_system, null: false, unique: true
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
  Float :volume_share_pct
  Float :requests_per_minute_limit
  Integer :daily_turnover_min
  Integer :daily_turnover_max
  
  index :payment_system, unique: true
  index :status
  index :priority
end

# Таблица operations_history
DB.create_table? :operations_history do
  String :operation_id, primary_key: true
  DateTime :created_at, null: false
  Integer :amount, null: false
  String :bank, null: false
  String :card_brand
  Integer :payment_system_id, null: false
  String :status, null: false
  Integer :latency_sec
  
  index :payment_system_id
  index :status
  index :created_at
end

# Таблица routing_decisions
DB.create_table? :routing_decisions do
  String :operation_id, primary_key: true
  Integer :selected_payment_system_id
  String :simulated_result
  Integer :latency_sec
  DateTime :created_at, null: false
  
  index :selected_payment_system_id
  index :created_at
end

# Таблица routing_attempts
DB.create_table? :routing_attempts do
  primary_key :attempt_id
  String :operation_id, null: false
  Integer :payment_system_id, null: false
  Integer :attempt_number, null: false
  String :decision, null: false
  String :reason
  DateTime :created_at, null: false
  
  unique [:operation_id, :payment_system_id]
  unique [:operation_id, :attempt_number]
  
  index :operation_id
  index :payment_system_id
  index :attempt_number
  index :decision
  index :created_at
end

# Таблица eligible_providers
DB.create_table? :eligible_providers do
  String :operation_id, null: false
  Integer :payment_system_id, null: false
  TrueClass :is_eligible, null: false
  DateTime :checked_at, null: false
  
  primary_key [:operation_id, :payment_system_id]
  
  index :operation_id
  index :payment_system_id
  index :is_eligible
end

# Таблица provider_skip_reasons
DB.create_table? :provider_skip_reasons do
  primary_key :skip_reason_id
  String :operation_id, null: false
  Integer :payment_system_id, null: false
  String :reason, null: false
  DateTime :created_at, null: false
  
  unique [:operation_id, :payment_system_id, :reason]
  
  index :operation_id
  index :payment_system_id
  index :created_at
end

# Таблица reference_decisions
DB.create_table? :reference_decisions do
  String :operation_id, primary_key: true
  Integer :required_payment_system_id
  String :reason, :text => true
end

puts "OK"
puts "Созданные таблицы: #{DB.tables.join(', ')}"