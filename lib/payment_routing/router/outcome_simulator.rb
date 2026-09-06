module PaymentRouting
  module Router
    class OutcomeSimulator
      APPROVED = "approved"

      def simulate(provider:, operation:)
        APPROVED
      end
    end
  end
end
