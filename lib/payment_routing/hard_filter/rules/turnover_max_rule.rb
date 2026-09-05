module PaymentRouting
  module HardFilter
    module Rules
      # Проверка 9 ("Фин. обязательство (максимум)"): расширение сверх ТЗ 6.1-6.8
      # (см. ТЗ, раздел "Дополнительные поля" - daily_turnover_max явно помечен
      # опциональным). Аналог DailyAmountLimitRule, но по обороту
      # (actuals.turnover_actual), а не по одобренной сумме - нижняя граница,
      # daily_turnover_min, - soft-goal рейтинга (см. Rating::Norms::TurnoverNorm),
      # а не hard-constraint. Лимит nil - обязательства по максимуму нет.
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
