require_relative "../../../test_helper"

module PaymentRouting
  module HardFilter
    module Rules
      class RequisitesRuleTest < Minitest::Test
        include TestFactories

        def test_passes_when_requisites_are_available
          p = provider(available_requisites: 5)

          assert_nil RequisitesRule.new.call(provider: p, operation: operation, actuals: actuals)
        end

        def test_excluded_when_no_requisites_are_available
          p = provider(available_requisites: 0)

          result = RequisitesRule.new.call(provider: p, operation: operation, actuals: actuals)

          assert_equal "no_available_requisites", result
        end

        def test_unknown_requisite_count_does_not_block
          p = provider(available_requisites: nil)

          assert_nil RequisitesRule.new.call(provider: p, operation: operation, actuals: actuals)
        end
      end
    end
  end
end
