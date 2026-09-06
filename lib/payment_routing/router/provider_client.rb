module PaymentRouting
  module Router
    class ProviderClient
      class UnavailableError < StandardError; end

      def attempt(provider:, operation:)
        nil
      end
    end
  end
end
