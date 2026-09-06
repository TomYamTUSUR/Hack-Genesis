module PaymentRouting
  module HardFilter
    module Rules
      class DailyAmountLimitRule < BaseRule
        REASON = "daily_amount_limit_exceeded"

        def call(provider:, operation:, actuals:)
          return nil if provider.daily_amount_limit.nil?

          REASON if provider.daily_approved_amount.to_f + operation.amount > provider.daily_amount_limit
        end
      end
    end
  end
end
