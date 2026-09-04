module PaymentRouting
  module Rating
    module Norms
      # Стратегия 6: по интенсивности (rate limit на терминал/провайдера).
      # Норма считается строго по rpm - в отличие от универсального LoadFactor,
      # её не должна перебивать загрузка по in_progress_count/amount, иначе
      # выбор этой стратегии не гарантировал бы приоритет по её же ключевому параметру.
      class IntensityNorm < BaseNorm
        KEY = :intensity

        def initialize(load_factor_calculator: LoadFactorCalculator.new)
          @load_factor_calculator = load_factor_calculator
        end

        def call(provider:, operation:, pool:)
          rpm_utilization = @load_factor_calculator.rpm_utilization(provider: provider, actuals: pool.actuals_for(provider))
          Constants::NORM_MAX - rpm_utilization
        end
      end
    end
  end
end
