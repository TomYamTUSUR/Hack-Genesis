require 'sequel'

module PaymentRouting
  module Db
    DEFAULT_PATH = File.join(__dir__, 'operations.db')

    def self.connect(path = DEFAULT_PATH)
      path.nil? ? Sequel.sqlite : Sequel.sqlite(path, timeout: 5_000)
    end

    def self.create_schema!(db)
      # Таблица operations_queue
      db.create_table? :operations_queue do
        String :operation_id, primary_key: true
        DateTime :created_at, null: false
        Integer :amount, null: false
        String :bank, null: false
        String :card_brand
        String :payout_requisite_sbp_phone
        String :payout_requisite_bank_name
      end

      # Таблица providers
      db.create_table? :providers do
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
        String :banks, text: true, default: '[]'
        TrueClass :exclude_banks, default: false
        Float :provider_margin_pct
        Float :merchant_margin_pct
        TrueClass :allow_negative_agreement, default: false
        String :note
        Float :volume_share_pct
        Float :requests_per_minute_limit
        Integer :daily_turnover_min
        Integer :daily_turnover_max
        Integer :preferred_range_min
        Integer :preferred_range_max

        index :payment_system, unique: true
        index :status
        index :priority
      end

      # Таблица operations_history
      db.create_table? :operations_history do
        String :operation_id, primary_key: true
        DateTime :created_at, null: false
        Integer :amount, null: false
        String :bank, null: false
        String :card_brand
        foreign_key :payment_system_id, :providers, key: :payment_system_id, null: false
        String :status, null: false
        Integer :latency_sec

        index :payment_system_id
        index :status
        index :created_at
      end

      # Таблица routing_decisions
      db.create_table? :routing_decisions do
        foreign_key :operation_id, :operations_queue, key: :operation_id, type: String, primary_key: true
        foreign_key :selected_payment_system_id, :providers, key: :payment_system_id, null: false
        String :simulated_result, null: false
        Integer :latency_sec, null: false
        DateTime :created_at, null: false

        index :selected_payment_system_id
        index :created_at
      end

      # Таблица routing_attempts
      db.create_table? :routing_attempts do
        primary_key :attempt_id
        foreign_key :operation_id, :routing_decisions, key: :operation_id, type: String, null: false
        foreign_key :payment_system_id, :providers, key: :payment_system_id, null: false
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
      db.create_table? :eligible_providers do
        foreign_key :operation_id, :operations_queue, key: :operation_id, type: String, null: false
        foreign_key :payment_system_id, :providers, key: :payment_system_id, null: false
        TrueClass :is_eligible, null: false
        DateTime :checked_at, null: false

        primary_key [:operation_id, :payment_system_id]

        index :operation_id
        index :payment_system_id
        index :is_eligible
      end

      # Таблица provider_skip_reasons
      db.create_table? :provider_skip_reasons do
        primary_key :skip_reason_id
        foreign_key :operation_id, :operations_queue, key: :operation_id, type: String, null: false
        foreign_key :payment_system_id, :providers, key: :payment_system_id, null: false
        String :reason, null: false
        DateTime :created_at, null: false

        unique [:operation_id, :payment_system_id, :reason]

        index :operation_id
        index :payment_system_id
        index :created_at
      end

      # Таблица reference_decisions
      db.create_table? :reference_decisions do
        foreign_key :operation_id, :operations_queue, key: :operation_id, type: String, primary_key: true
        foreign_key :required_payment_system_id, :providers, key: :payment_system_id, null: false
        String :reason, text: true
      end

      upgrade_schema!(db)
      db
    end

    def self.upgrade_schema!(db)
      additions = {
        providers: { daily_approved_date: String, daily_utc_offset: Integer },
        routing_decisions: { explanation: String },
        routing_attempts: { details: String, dispatched_at: DateTime }
      }
      db.transaction do
        additions.each do |table, fields|
          columns = db.schema(table).map(&:first)
          fields.each do |name, type|
            db.alter_table(table) { add_column name, type } unless columns.include?(name)
          end
        end
      end
    end
  end
end
