require_relative "../../../test_helper"

module PaymentRouting
  module HardFilter
    module Rules
      class InProgressRuleTest < Minitest::Test
        include TestFactories

        def test_passes_when_under_both_limits
          p = provider(in_progress_count: 2, in_progress_count_limit: 10,
                       in_progress_amount: 100_000, in_progress_amount_limit: 1_000_000)

          assert_nil InProgressRule.new.call(provider: p, operation: operation(amount: 50_000), actuals: actuals)
        end

        def test_excluded_when_count_already_at_the_limit
          p = provider(in_progress_count: 10, in_progress_count_limit: 10,
                       in_progress_amount: 0, in_progress_amount_limit: nil)

          result = InProgressRule.new.call(provider: p, operation: operation(amount: 1), actuals: actuals)

          assert_equal "in_progress_limit_exceeded", result
        end

        def test_excluded_when_operation_would_cross_the_amount_limit
          p = provider(in_progress_count: 0, in_progress_count_limit: nil,
                       in_progress_amount: 980_000, in_progress_amount_limit: 1_000_000)

          result = InProgressRule.new.call(provider: p, operation: operation(amount: 30_000), actuals: actuals)

          assert_equal "in_progress_limit_exceeded", result
        end

        def test_nil_limits_mean_no_restriction
          p = provider(in_progress_count: 999, in_progress_count_limit: nil,
                       in_progress_amount: 999_999_999, in_progress_amount_limit: nil)

          assert_nil InProgressRule.new.call(provider: p, operation: operation(amount: 1), actuals: actuals)
        end
      end
    end
  end
end
