module PaymentRouting
  module HardFilter
    module Rules
      class AmountRangeRule < BaseRule
        BELOW_MINIMUM_REASON = "amount_below_minimum"
        EXCEEDS_LIMIT_REASON = "amount_exceeds_limit"

        def call(provider:, operation:, actuals:)
          return BELOW_MINIMUM_REASON if below_min?(provider, operation)
          return EXCEEDS_LIMIT_REASON if above_max?(provider, operation)

          nil
        end

        private

        def below_min?(provider, operation)
          !provider.limit_amount_min.nil? && operation.amount < provider.limit_amount_min
        end

        def above_max?(provider, operation)
          !provider.limit_amount_max.nil? && operation.amount > provider.limit_amount_max
        end
      end
    end
  end
end
