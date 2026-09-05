module PaymentRouting
  module HardFilter
    # Прогоняет провайдера через весь набор hard-constraints для конкретной
    # операции (см. TASK_SPEC.md, раздел 6, и rules/). Провайдеры, прошедшие
    # Engine, дальше попадают в Rating::RatingPool - блок стратегий/рейтинга
    # работает только с ними (ТЗ, раздел 3: "Hard Constraints всегда
    # применяются ДО выбора стратегии").
    class Engine
      RULES = [
        Rules::StatusRule.new,
        Rules::AmountRangeRule.new,
        Rules::DailyAmountLimitRule.new,
        Rules::InProgressRule.new,
        Rules::BankRule.new,
        Rules::MarginRule.new,
        Rules::RequisitesRule.new,
        Rules::IntensityRule.new,
        Rules::TurnoverMaxRule.new
      ].freeze

      def initialize(rules: RULES)
        @rules = rules
      end

      def call(provider:, operation:, actuals:)
        reasons = @rules.filter_map { |rule| rule.call(provider: provider, operation: operation, actuals: actuals) }
        Result.new(reasons: reasons)
      end

      # providers: [Provider]; actuals_by_provider: Hash{String (payment_system) => ProviderActuals}
      # (тот же формат, что отдаёт HistoricalActualsProvider#load).
      # Возвращает Hash{Provider => Result} - по одному результату на каждого
      # переданного провайдера, эту же форму ожидает eligible_providers/
      # provider_skip_reasons при записи в БД.
      def call_all(providers:, operation:, actuals_by_provider:)
        providers.to_h { |provider| [provider, call(provider: provider, operation: operation, actuals: actuals_by_provider.fetch(provider.payment_system))] }
      end
    end
  end
end
