module PaymentRouting
  module HardFilter
    module Rules
      # Проверка 7 ("Реквизиты", ТЗ 6.7): провайдеру физически нечем принять
      # выплату, если available_requisites == 0. nil (неизвестно) не блокирует -
      # в отличие от 0, это не то же самое, что "реквизитов нет".
      class RequisitesRule < BaseRule
        REASON = "no_available_requisites"

        def call(provider:, operation:, actuals:)
          REASON if !provider.available_requisites.nil? && provider.available_requisites.zero?
        end
      end
    end
  end
end
