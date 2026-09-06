module PaymentRouting
  module HardFilter
    module Rules
      # Проверка "Реквизиты": провайдеру нечем принять выплату, если available_requisites == 0
      class RequisitesRule < BaseRule
        REASON = "no_available_requisites"

        def call(provider:, operation:, actuals:)
          REASON if !provider.available_requisites.nil? && provider.available_requisites.zero?
        end
      end
    end
  end
end
