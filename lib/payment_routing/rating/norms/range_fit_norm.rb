module PaymentRouting
  module Rating
    module Norms
      # Стратегия 4: маршрутизация по диапазону суммы. Чем ближе сумма заявки
      # к середине "предпочтительного" диапазона провайдера, тем выше норма.
      class RangeFitNorm < BaseNorm
        KEY = :range_fit

        def call(provider:, operation:, pool:)
          range = provider.preferred_range
          # Провайдер без заданного preferred_range (ещё не дополнен - см.
          # ProviderRegistry) этой стратегией не наказывается и не поощряется.
          return Constants::NORM_MAX if range.nil? || range.halfwidth.zero?

          fit = 1 - (operation.amount - range.mid).abs / range.halfwidth
          MathUtils.clip(fit, Constants::NORM_MIN, Constants::NORM_MAX)
        end
      end
    end
  end
end
