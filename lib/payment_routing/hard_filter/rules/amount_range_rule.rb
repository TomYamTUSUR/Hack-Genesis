module PaymentRouting
  module HardFilter
    module Rules
      # Проверка 2 ("Диапазон суммы чека", ТЗ 6.2): limit_amount_min/max -
      # допустимый диапазон суммы для провайдера. Граница nil значит "без
      # ограничения" с этой стороны (см. spacepayments/self-provider в data/providers.json).
      class AmountRangeRule < BaseRule
        REASON = "amount_out_of_range"

        def call(provider:, operation:, actuals:)
          REASON if below_min?(provider, operation) || above_max?(provider, operation)
        end

        private

        def below_min?(provider, operation)
          !provider.limit_amount_min.nil? && operation.amount < provider.limit_amount_min
        end

        def above_max?(provider, operation)
          !provider.limit_amount_max.nil? && operation.amount > provider.limit_amount_max
        end
      end
    end
  end
end
