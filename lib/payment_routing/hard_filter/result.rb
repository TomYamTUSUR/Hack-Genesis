module PaymentRouting
  module HardFilter
    # Итог прогона всех правил для пары (provider, operation). reasons - коды
    # ВСЕХ сработавших правил, не только первого - так и хранится
    # provider_skip_reasons (несколько строк на пару операция/провайдер, см.
    # db/database.rb), чтобы было видно все причины исключения сразу, а не
    # только первую попавшуюся.
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
