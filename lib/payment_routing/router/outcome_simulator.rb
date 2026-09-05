module PaymentRouting
  module Router
    # Симулирует итог обработки уже выбранного провайдера (simulated_result в
    # выходном формате). v1 всегда approved - выделен в отдельный класс с одним
    # методом именно для того, чтобы заменить на расчёт по conversion_24h
    # позже, не трогая остальной Router.
    class OutcomeSimulator
      APPROVED = "approved"

      def simulate(provider:, operation:)
        APPROVED
      end
    end
  end
end
