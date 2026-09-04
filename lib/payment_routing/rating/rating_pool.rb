module PaymentRouting
  module Rating
    # Контекст ранжирования: провайдеры, уже прошедшие hard-constraints, вместе
    # с их ProviderActuals. Даёт норм-калькуляторам min/max по пулу (нужно
    # PriorityNorm/ConversionNorm) и признак "пул из одного провайдера" -
    # по формуле в этом случае norm = 1 для всех, кому нужен пул.
    class RatingPool
      def initialize(providers:, actuals_by_provider:)
        @providers = providers
        @actuals_by_provider = actuals_by_provider
      end

      def single_candidate?
        @providers.size <= 1
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
