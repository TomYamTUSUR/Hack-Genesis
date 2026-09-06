module PaymentRouting
  module Rating
    module Norms
      # Стратегия 7: фин. обязательства (минимальный дневной оборот). Провайдер,
      # не набравший daily_turnover_min, получает норму ближе к 1. Провайдер без
      # такого обязательства получает нейтральные 0.5, ниже бонуса за недобор.
      class TurnoverNorm < BaseNorm
        KEY = :turnover

        def call(provider:, operation:, pool:)
          return Constants::NEUTRAL_NORM if provider.daily_turnover_min.nil? || provider.daily_turnover_min.zero?

          deviation_norm(target: provider.daily_turnover_min, actual: pool.actuals_for(provider).turnover_actual)
        end
      end
    end
  end
end
