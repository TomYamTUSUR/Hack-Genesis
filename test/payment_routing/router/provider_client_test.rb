require_relative "../../test_helper"

module PaymentRouting
  module Router
    class ProviderClientTest < Minitest::Test
      include TestFactories

      def test_never_raises_in_v1
        ProviderClient.new.attempt(provider: provider, operation: operation)
      end
    end
  end
end
