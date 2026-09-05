module PaymentRouting
  module HardFilter
    module Rules
      # Проверка 1 ("Статус", ТЗ 6.1): провайдер, отключённый вручную
      # (status != "active"), не участвует в роутинге ни при каких условиях операции.
      class StatusRule < BaseRule
        ACTIVE_STATUS = "active"
        REASON = "status_not_active"

        def call(provider:, operation:, actuals:)
          REASON unless provider.status == ACTIVE_STATUS
        end
      end
    end
  end
end
