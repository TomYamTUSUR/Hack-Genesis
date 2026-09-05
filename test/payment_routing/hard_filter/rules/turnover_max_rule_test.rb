require_relative "../../../test_helper"

module PaymentRouting
  module HardFilter
    module Rules
      class TurnoverMaxRuleTest < Minitest::Test
        include TestFactories

        def test_passes_when_still_under_the_limit
          p = provider(daily_turnover_max: 4_000_000)

          result = TurnoverMaxRule.new.call(provider: p, operation: operation(amount: 100_000), actuals: actuals(turnover_actual: 3_000_000))

          assert_nil result
        end

        def test_excluded_when_operation_would_cross_the_limit
          p = provider(daily_turnover_max: 4_000_000)

          result = TurnoverMaxRule.new.call(provider: p, operation: operation(amount: 100_000), actuals: actuals(turnover_actual: 3_950_000))

          assert_equal "daily_turnover_max_exceeded", result
        end

        def test_nil_limit_means_no_restriction
          p = provider(daily_turnover_max: nil)

          result = TurnoverMaxRule.new.call(provider: p, operation: operation(amount: 100_000), actuals: actuals(turnover_actual: 999_999_999))

          assert_nil result
        end
      end
    end
  end
end
