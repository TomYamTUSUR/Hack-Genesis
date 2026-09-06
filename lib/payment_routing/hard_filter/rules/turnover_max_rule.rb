module PaymentRouting
  module HardFilter
    module Rules
      # Проверка "Фин. обязательство (максимум)": проверка привышения фин.обязательства
      class TurnoverMaxRule < BaseRule
        REASON = "daily_turnover_max_exceeded"

        def call(provider:, operation:, actuals:)
          return nil if provider.daily_turnover_max.nil?

          REASON if actuals.turnover_actual.to_f + operation.amount > provider.daily_turnover_max
        end
      end
    end
  end
end
