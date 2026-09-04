module PaymentRouting
  module Rating
    module Norms
      # Стратегия 5: приоритизация по конверсии за 24ч - выше конверсия, выше норма.
      class ConversionNorm < BaseNorm
        KEY = :conversion

        def call(provider:, operation:, pool:)
          min_max_norm(value: provider.conversion_24h, min: pool.min_conversion, max: pool.max_conversion)
        end
      end
    end
  end
end
