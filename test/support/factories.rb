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
          in_progress_amount: 0, in_progress_amount_limit: nil
        }.merge(overrides)
      )
    end

    def actuals(overrides = {})
      ProviderActuals.new(
        **{
          count_share_actual: 0, volume_share_actual: 0, turnover_actual: 0, rpm_used: 0
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
  end
end
