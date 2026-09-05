require_relative "../../../test_helper"

module PaymentRouting
  module HardFilter
    module Rules
      class AmountRangeRuleTest < Minitest::Test
        include TestFactories

        def test_passes_when_amount_is_within_range
          p = provider(limit_amount_min: 1_000, limit_amount_max: 100_000)

          assert_nil AmountRangeRule.new.call(provider: p, operation: operation(amount: 50_000), actuals: actuals)
        end

        def test_excluded_when_below_minimum
          p = provider(limit_amount_min: 1_000, limit_amount_max: 100_000)

          result = AmountRangeRule.new.call(provider: p, operation: operation(amount: 500), actuals: actuals)

          assert_equal "amount_below_minimum", result
        end

        def test_excluded_when_above_maximum
          p = provider(limit_amount_min: 1_000, limit_amount_max: 100_000)

          result = AmountRangeRule.new.call(provider: p, operation: operation(amount: 150_000), actuals: actuals)

          assert_equal "amount_exceeds_limit", result
        end

        def test_nil_bounds_mean_no_restriction_on_that_side
          p = provider(limit_amount_min: nil, limit_amount_max: nil)

          assert_nil AmountRangeRule.new.call(provider: p, operation: operation(amount: 999_999_999), actuals: actuals)
        end
      end
    end
  end
end
