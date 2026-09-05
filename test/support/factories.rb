module PaymentRouting
  module TestFactories
    module_function

    def provider(overrides = {})
      Provider.new(
        **{
          payment_system: "test", priority: 1, conversion_24h: 0.9,
          traffic_percentage: 40, volume_share_pct: 40,
          preferred_range: AmountRange.new(min: 0, max: 100_000),
          requests_per_minute_limit: nil, daily_turnover_min: nil,
          in_progress_count: 0, in_progress_count_limit: nil,
          in_progress_amount: 0, in_progress_amount_limit: nil,
          # HardFilter: значения по умолчанию нейтральны - ничего не исключают,
          # чтобы существующие тесты (rating/strategies), которым hard-constraints
          # не важны, не завязывались на них.
          status: "active", limit_amount_min: nil, limit_amount_max: nil,
          daily_amount_limit: nil, daily_approved_amount: 0,
          available_requisites: 1, banks: [], exclude_banks: false,
          provider_margin_pct: nil, merchant_margin_pct: nil, allow_negative_agreement: false,
          daily_turnover_max: nil
        }.merge(overrides)
      )
    end

    def actuals(overrides = {})
      ProviderActuals.new(
        **{
          count_share_actual: 0, volume_share_actual: 0, count_actual: 0, volume_actual: 0,
          turnover_actual: 0, rpm_used: 0
        }.merge(overrides)
      )
    end

    def operation(overrides = {})
      Operation.new(**{ operation_id: "op_test", amount: 10_000 }.merge(overrides))
    end

    # provider_actuals_pairs: Hash{Provider => ProviderActuals}
    def rating_pool(provider_actuals_pairs)
      Rating::RatingPool.new(
        providers: provider_actuals_pairs.keys,
        actuals_by_provider: provider_actuals_pairs.to_h { |p, a| [p.payment_system, a] }
      )
    end

    # In-memory БД с реальными data/* поверх схемы - для тестов, которым нужен
    # настоящий ProviderRegistry/HistoricalActualsProvider/OperationQueueLoader
    # (они читают только БД, файлы не читают).
    def seeded_db
      db = Db.connect(nil)
      Db.create_schema!(db)
      config = RoutingConfig.new

      Importers::ProvidersImporter.new(db: db, providers_file: config.providers_file).import
      Importers::BusinessParametersImporter.new(db: db, business_parameters_file: config.business_parameters_file).import
      Importers::OperationsQueueImporter.new(db: db, queue_file: config.operations_queue_file).import
      Importers::OperationsHistoryImporter.new(db: db, history_file: config.operations_history_file).import

      db
    end
  end
end
