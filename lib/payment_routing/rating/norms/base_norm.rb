module PaymentRouting
  module Rating
    module Norms
      # Интерфейс norm_i(p): приводит один критерий стратегии к шкале [0,1].
      # KEY связывает норм-калькулятор с весом, посчитанным StrategyWeightCalculator.
      class BaseNorm
        KEY = nil

        def call(provider:, operation:, pool:)
          raise NotImplementedError, "#{self.class} must implement #call"
        end

        # Общая для нескольких норм симметричная формула отклонения от цели:
        # rd = (target - actual) / target, clip[-1,1], norm = (rd+1)/2.
        # Провайдер ниже цели (actual < target) -> rd>0 -> norm ближе к 1 (нужно больше трафика).
        def deviation_norm(target:, actual:)
          return Constants::SINGLE_CANDIDATE_NORM if target.nil? || target.zero?

          relative_deviation = MathUtils.clip(
            (target - actual).to_f / target,
            Constants::RELATIVE_DEVIATION_MIN,
            Constants::RELATIVE_DEVIATION_MAX
          )
          (relative_deviation + 1) / 2.0
        end

        # Общая для PriorityNorm/ConversionNorm min-max нормализация по пулу.
        def min_max_norm(value:, min:, max:)
          return Constants::SINGLE_CANDIDATE_NORM if min == max

          (value - min).to_f / (max - min)
        end
      end
    end
  end
end
