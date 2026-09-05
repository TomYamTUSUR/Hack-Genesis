module PaymentRouting
  module HardFilter
    module Rules
      # Проверка 3 ("Дневной максимум", ТЗ 6.3): операция не должна увести уже
      # одобренный сегодня оборот провайдера (daily_approved_amount) выше
      # daily_amount_limit. Лимит nil - обязательства по дневному максимуму нет.
      class DailyAmountLimitRule < BaseRule
        REASON = "daily_amount_limit_exceeded"

        def call(provider:, operation:, actuals:)
          return nil if provider.daily_amount_limit.nil?

          REASON if provider.daily_approved_amount.to_f + operation.amount > provider.daily_amount_limit
        end
      end
    end
  end
end
