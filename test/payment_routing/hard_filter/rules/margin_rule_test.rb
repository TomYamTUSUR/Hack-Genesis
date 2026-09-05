require_relative "../../../test_helper"

module PaymentRouting
  module HardFilter
    module Rules
      class MarginRuleTest < Minitest::Test
        include TestFactories

        def test_passes_when_provider_margin_is_not_above_merchant_margin
          p = provider(provider_margin_pct: 1.0, merchant_margin_pct: 1.5, allow_negative_agreement: false)

          assert_nil MarginRule.new.call(provider: p, operation: operation, actuals: actuals)
        end

        def test_excluded_when_provider_margin_is_above_merchant_margin
          p = provider(provider_margin_pct: 2.0, merchant_margin_pct: 1.5, allow_negative_agreement: false)

          result = MarginRule.new.call(provider: p, operation: operation, actuals: actuals)

          assert_equal "margin_not_acceptable", result
        end

        def test_allow_negative_agreement_lifts_the_check
          p = provider(provider_margin_pct: 2.0, merchant_margin_pct: 1.5, allow_negative_agreement: true)

          assert_nil MarginRule.new.call(provider: p, operation: operation, actuals: actuals)
        end

        def test_missing_margin_data_does_not_block
          p = provider(provider_margin_pct: nil, merchant_margin_pct: 1.5, allow_negative_agreement: false)

          assert_nil MarginRule.new.call(provider: p, operation: operation, actuals: actuals)
        end
      end
    end
  end
end
