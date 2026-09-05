require_relative "../../../test_helper"

module PaymentRouting
  module HardFilter
    module Rules
      class StatusRuleTest < Minitest::Test
        include TestFactories

        def test_passes_when_active
          p = provider(status: "active")

          assert_nil StatusRule.new.call(provider: p, operation: operation, actuals: actuals)
        end

        def test_excluded_when_not_active
          p = provider(status: "paused")

          result = StatusRule.new.call(provider: p, operation: operation, actuals: actuals)

          assert_equal "status_not_active", result
        end
      end
    end
  end
end
