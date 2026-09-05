require_relative "../../test_helper"

module PaymentRouting
  module HardFilter
    class EngineTest < Minitest::Test
      include TestFactories

      def test_a_provider_with_no_violations_is_eligible
        p = provider
        result = Engine.new.call(provider: p, operation: operation, actuals: actuals)

        assert result.eligible?
        assert_empty result.reasons
      end

      def test_a_single_violation_makes_the_provider_ineligible
        p = provider(status: "paused")
        result = Engine.new.call(provider: p, operation: operation, actuals: actuals)

        refute result.eligible?
        assert_equal ["status_not_active"], result.reasons
      end

      def test_all_failing_rules_are_reported_not_just_the_first
        p = provider(status: "paused", available_requisites: 0, banks: %w[sberbank], exclude_banks: false)
        result = Engine.new.call(provider: p, operation: operation(bank: "vtb"), actuals: actuals)

        refute result.eligible?
        assert_equal %w[status_not_active bank_not_allowed no_available_requisites], result.reasons
      end

      def test_call_all_evaluates_every_provider_against_its_own_actuals
        eligible_provider = provider(payment_system: "ok")
        blocked_provider = provider(payment_system: "blocked", status: "paused")

        results = Engine.new.call_all(
          providers: [eligible_provider, blocked_provider],
          operation: operation,
          actuals_by_provider: { "ok" => actuals, "blocked" => actuals }
        )

        assert results.fetch(eligible_provider).eligible?
        refute results.fetch(blocked_provider).eligible?
      end
    end
  end
end
