module PaymentRouting
  module Rating
    # Контекст ранжирования: провайдеры, уже прошедшие hard-constraints, вместе
    # с их ProviderActuals. Даёт норм-калькуляторам min/max по пулу (нужно
    # PriorityNorm/ConversionNorm; при min == max BaseNorm#min_max_norm сам
    # возвращает нейтральную норму, в том числе для пула из одного провайдера).
    class RatingPool
      def initialize(providers:, actuals_by_provider:)
        @providers = providers
        @actuals_by_provider = actuals_by_provider
      end

      def actuals_for(provider)
        @actuals_by_provider.fetch(provider.payment_system)
      end

      def min_priority
        @min_priority ||= @providers.map(&:priority).min
      end

      def max_priority
        @max_priority ||= @providers.map(&:priority).max
      end

      def min_conversion
        @min_conversion ||= @providers.map(&:conversion_24h).min
      end

      def max_conversion
        @max_conversion ||= @providers.map(&:conversion_24h).max
      end
    end
  end
end
