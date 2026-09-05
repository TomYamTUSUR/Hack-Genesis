module PaymentRouting
  module HardFilter
    module Rules
      # Проверка 5 ("Банковский фильтр", ТЗ 6.5): banks + exclude_banks. Пустой
      # banks - без ограничений (независимо от exclude_banks). Иначе banks -
      # whitelist (exclude_banks: false, банк операции обязан быть в списке)
      # или blacklist (exclude_banks: true, банк операции не должен быть в списке).
      class BankRule < BaseRule
        REASON = "bank_not_allowed"

        def call(provider:, operation:, actuals:)
          return nil if provider.banks.empty?

          listed = provider.banks.include?(operation.bank)
          excluded = provider.exclude_banks ? listed : !listed
          REASON if excluded
        end
      end
    end
  end
end
