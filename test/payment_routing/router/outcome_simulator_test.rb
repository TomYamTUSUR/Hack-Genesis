require_relative "../../test_helper"

module PaymentRouting
  module Router
    class OutcomeSimulatorTest < Minitest::Test
      include TestFactories

      def test_always_approved_in_v1
        assert_equal "approved", OutcomeSimulator.new.simulate(provider: provider, operation: operation)
      end
    end
  end
end
