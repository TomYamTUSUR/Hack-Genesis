require_relative "../../test_helper"

module PaymentRouting
  module Router
    class RunStateTest < Minitest::Test
      include TestFactories

      def setup
        @vipay = provider(payment_system: "vipay")
        @state = RunState.new(providers: [@vipay], actuals_by_provider: { "vipay" => actuals })
      end

      def test_looks_up_provider_and_actuals_by_payment_system
        assert_same @vipay, @state.provider("vipay")
        assert_equal 0, @state.actuals("vipay").rpm_used
      end

      def test_replace_provider_is_visible_on_the_next_lookup
        updated = @vipay.with(in_progress_count: 99)

        @state.replace_provider(updated)

        assert_equal 99, @state.provider("vipay").in_progress_count
      end

      def test_replace_actuals_is_visible_on_the_next_lookup
        @state.replace_actuals("vipay", actuals(turnover_actual: 500))

        assert_equal 500, @state.actuals("vipay").turnover_actual
      end
    end
  end
end
