module PaymentRouting
  module Rating
    module Norms
      # Стратегия 7: фин. обязательства (минимальный дневной оборот). Провайдер,
      # не набравший daily_turnover_min, получает норму ближе к 1. Провайдер без
      # такого обязательства (target = nil) не штрафуется и не поощряется - deviation_norm
      # в этом случае возвращает нейтрально-максимальную норму.
      class TurnoverNorm < BaseNorm
        KEY = :turnover

        def call(provider:, operation:, pool:)
          deviation_norm(target: provider.daily_turnover_min, actual: pool.actuals_for(provider).turnover_actual)
        end
      end
    end
  end
end
