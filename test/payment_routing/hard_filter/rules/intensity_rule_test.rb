require_relative "../../../test_helper"

module PaymentRouting
  module HardFilter
    module Rules
      class IntensityRuleTest < Minitest::Test
        include TestFactories

        def test_passes_when_under_the_rate_limit
          p = provider(requests_per_minute_limit: 60)

          assert_nil IntensityRule.new.call(provider: p, operation: operation, actuals: actuals(rpm_used: 10))
        end

        def test_excluded_when_exactly_at_the_rate_limit
          p = provider(requests_per_minute_limit: 60)

          result = IntensityRule.new.call(provider: p, operation: operation, actuals: actuals(rpm_used: 60))

          assert_equal "rate_limit_exceeded", result
        end

        def test_excluded_when_over_the_rate_limit
          p = provider(requests_per_minute_limit: 60)

          result = IntensityRule.new.call(provider: p, operation: operation, actuals: actuals(rpm_used: 61))

          assert_equal "rate_limit_exceeded", result
        end

        def test_nil_limit_means_no_restriction
          p = provider(requests_per_minute_limit: nil)

          assert_nil IntensityRule.new.call(provider: p, operation: operation, actuals: actuals(rpm_used: 999))
        end
      end
    end
  end
end
