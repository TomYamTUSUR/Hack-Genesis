require 'sequel'

module PaymentRouting
  # Подключение к SQLite и определение схемы - в одном месте, чтобы
  # db/create_tables.rb (реальная БД) и тесты импортёров (in-memory БД)
  # гарантированно работали с одной и той же схемой, а не с двумя копиями DDL.
  #
  # Таблицы и связи соответствуют ER-диаграмме (dbdiagram.io) - см. Ref-строки
  # в комментариях у каждого foreign_key.
  module Db
    DEFAULT_PATH = File.join(__dir__, 'operations.db')

    # path: nil -> in-memory БД (используется тестами импортёров).
    def self.connect(path = DEFAULT_PATH)
      path.nil? ? Sequel.sqlite : Sequel.sqlite(path)
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
        # Приоритетный диапазон суммы для стратегии "по сумме чека" (см. RangeFitNorm) -
        # не приходит из data/providers.json, дополняется отдельным блоком. Пока null,
        # ProviderRegistry подставляет вместо него limit_amount_min/max.
        Integer :preferred_range_min
        Integer :preferred_range_max

        index :payment_system, unique: true
        index :status
        index :priority
      end

      # Таблица operations_history
      # Ref: operations_history.payment_system_id > providers.payment_system_id
      db.create_table? :operations_history do
        String :operation_id, primary_key: true
        DateTime :created_at, null: false
        Integer :amount, null: false
        String :bank, null: false
        String :card_brand
        foreign_key :payment_system_id, :providers, null: false
        String :status, null: false
        Integer :latency_sec

        index :payment_system_id
        index :status
        index :created_at
      end

      # Таблица routing_decisions
      # Ref: routing_decisions.operation_id > operations_queue.operation_id
      # Ref: routing_decisions.selected_payment_system_id > providers.payment_system_id
      db.create_table? :routing_decisions do
        foreign_key :operation_id, :operations_queue, type: String, primary_key: true
        # Обязательные поля по формату ответа (см. ТЗ, "Формат результата роутинга"):
        # выбранный провайдер и симулированный результат должны быть у каждого решения.
        foreign_key :selected_payment_system_id, :providers, null: false
        String :simulated_result, null: false
        Integer :latency_sec, null: false
        DateTime :created_at, null: false

        index :selected_payment_system_id
        index :created_at
      end

      # Таблица routing_attempts
      # Ref: routing_attempts.operation_id > routing_decisions.operation_id
      # Ref: routing_attempts.payment_system_id > providers.payment_system_id
      db.create_table? :routing_attempts do
        primary_key :attempt_id
        foreign_key :operation_id, :routing_decisions, type: String, null: false
        foreign_key :payment_system_id, :providers, null: false
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
      # Ref: eligible_providers.operation_id > operations_queue.operation_id
      # Ref: eligible_providers.payment_system_id > providers.payment_system_id
      db.create_table? :eligible_providers do
        foreign_key :operation_id, :operations_queue, type: String, null: false
        foreign_key :payment_system_id, :providers, null: false
        TrueClass :is_eligible, null: false
        DateTime :checked_at, null: false

        primary_key [:operation_id, :payment_system_id]

        index :operation_id
        index :payment_system_id
        index :is_eligible
      end

      # Таблица provider_skip_reasons
      # Ref: provider_skip_reasons.operation_id > operations_queue.operation_id
      # Ref: provider_skip_reasons.payment_system_id > providers.payment_system_id
      db.create_table? :provider_skip_reasons do
        primary_key :skip_reason_id
        foreign_key :operation_id, :operations_queue, type: String, null: false
        foreign_key :payment_system_id, :providers, null: false
        String :reason, null: false
        DateTime :created_at, null: false

        unique [:operation_id, :payment_system_id, :reason]

        index :operation_id
        index :payment_system_id
        index :created_at
      end

      # Таблица reference_decisions
      # Ref: reference_decisions.operation_id > operations_queue.operation_id
      # Ref: reference_decisions.required_payment_system_id > providers.payment_system_id
      db.create_table? :reference_decisions do
        foreign_key :operation_id, :operations_queue, type: String, primary_key: true
        foreign_key :required_payment_system_id, :providers, null: false
        String :reason, text: true
      end

      db
    end
  end
end
