require_relative "../../../test_helper"

module PaymentRouting
  module HardFilter
    module Rules
      class DailyAmountLimitRuleTest < Minitest::Test
        include TestFactories

        def test_passes_when_still_under_the_limit
          p = provider(daily_amount_limit: 5_000_000, daily_approved_amount: 3_000_000)

          assert_nil DailyAmountLimitRule.new.call(provider: p, operation: operation(amount: 100_000), actuals: actuals)
        end

        def test_excluded_when_operation_would_cross_the_limit
          p = provider(daily_amount_limit: 5_000_000, daily_approved_amount: 4_950_000)

          result = DailyAmountLimitRule.new.call(provider: p, operation: operation(amount: 100_000), actuals: actuals)

          assert_equal "daily_amount_limit_exceeded", result
        end

        def test_nil_limit_means_no_restriction
          p = provider(daily_amount_limit: nil, daily_approved_amount: 999_999_999)

          assert_nil DailyAmountLimitRule.new.call(provider: p, operation: operation(amount: 100_000), actuals: actuals)
        end
      end
    end
  end
end
