module PaymentRouting
  module HardFilter
    # Прогоняет провайдера через весь набор hard-constraints для конкретной операции
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
        fields = %i[status limit_amount_min limit_amount_max daily_amount_limit daily_approved_amount
                    in_progress_count in_progress_count_limit in_progress_amount in_progress_amount_limit
                    banks exclude_banks available_requisites provider_margin_pct merchant_margin_pct
                    allow_negative_agreement requests_per_minute_limit daily_turnover_max]
        details = {
          "operation" => { "amount" => operation.amount, "bank" => operation.bank },
          "provider" => fields.to_h { |field| [field.to_s, provider.public_send(field)] },
          "actuals" => { "rpm_used" => actuals.rpm_used, "turnover_actual" => actuals.turnover_actual }
        }
        Result.new(reasons: reasons, details: details)
      end

      def call_all(providers:, operation:, actuals_by_provider:)
        providers.to_h { |provider| [provider, call(provider: provider, operation: operation, actuals: actuals_by_provider.fetch(provider.payment_system))] }
      end
    end
  end
end
