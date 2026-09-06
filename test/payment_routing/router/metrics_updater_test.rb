require_relative "../../test_helper"

module PaymentRouting
  module Router
    class MetricsUpdaterTest < Minitest::Test
      include TestFactories

      def setup
        @provider = provider(payment_system: "vipay", in_progress_count: 2, in_progress_amount: 50_000, daily_approved_amount: 100_000)
        @state = RunState.new(providers: [@provider], actuals_by_provider: { "vipay" => actuals(turnover_actual: 200_000) })
        @operation = operation(amount: 10_000)
        @rated_payment_systems = ["vipay"]
      end

      def apply(simulated_result)
        MetricsUpdater.new.apply(
          state: @state, provider: @provider, operation: @operation, simulated_result: simulated_result,
          rated_payment_systems: @rated_payment_systems
        )
      end

      def test_terminal_outcome_does_not_add_in_progress_work
        apply("rejected")

        updated = @state.provider("vipay")
        assert_equal 2, updated.in_progress_count
        assert_equal 50_000, updated.in_progress_amount
      end

      def test_daily_approved_amount_and_turnover_only_increment_when_approved
        apply("approved")

        assert_equal 110_000, @state.provider("vipay").daily_approved_amount
        assert_equal 210_000, @state.actuals("vipay").turnover_actual
      end

      def test_daily_approved_amount_and_turnover_stay_put_when_not_approved
        apply("expired")

        assert_equal 100_000, @state.provider("vipay").daily_approved_amount
        assert_equal 200_000, @state.actuals("vipay").turnover_actual
      end

      def test_shares_are_recalculated_across_all_rated_providers_when_approved
        other = provider(payment_system: "payflow")
        @state = RunState.new(
          providers: [@provider, other],
          actuals_by_provider: {
            "vipay" => actuals(count_actual: 3, volume_actual: 30_000),
            "payflow" => actuals(count_actual: 1, volume_actual: 10_000)
          }
        )
        @rated_payment_systems = %w[vipay payflow]

        apply("approved")

        assert_in_delta 80.0, @state.actuals("vipay").count_share_actual
        assert_in_delta 20.0, @state.actuals("payflow").count_share_actual
        assert_in_delta 80.0, @state.actuals("vipay").volume_share_actual, 0.01
        assert_in_delta 20.0, @state.actuals("payflow").volume_share_actual, 0.01
      end

      def test_shares_are_not_recalculated_when_not_approved
        @state.replace_actuals("vipay", actuals(count_share_actual: 42, volume_share_actual: 42))

        apply("rejected")

        assert_equal 42, @state.actuals("vipay").count_share_actual
      end

      def test_shares_include_approved_fallback_operations
        @state.replace_actuals("vipay", actuals(count_share_actual: 42, volume_share_actual: 42))
        @rated_payment_systems = []

        apply("approved")

        assert_equal 100, @state.actuals("vipay").count_share_actual
      end
    end
  end
end
