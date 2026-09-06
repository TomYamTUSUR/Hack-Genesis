module PaymentRouting
  module HardFilter
    # Итог прогона всех правил
    class Result
      attr_reader :reasons, :details

      def initialize(reasons:, details: {})
        @reasons = reasons
        @details = details
      end

      def eligible?
        reasons.empty?
      end
    end
  end
end
