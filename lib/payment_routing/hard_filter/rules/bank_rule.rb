module PaymentRouting
  module HardFilter
    module Rules
      # Проверка "Банковский фильтр": banks + exclude_banks.
      class BankRule < BaseRule
        REASON = "bank_not_in_list"

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
