module PaymentRouting
  module HardFilter
    module Rules
      # Проверка 2 ("Диапазон суммы чека", ТЗ 6.2): limit_amount_min/max -
      # допустимый диапазон суммы для провайдера. Граница nil значит "без
      # ограничения" с этой стороны (см. spacepayments/self-provider в data/providers.json).
      # Два разных кода причины (а не один общий) - они дословно совпадают со
      # значениями в data/reference_decisions.json (skip_reasons_expected), по
      # которым сверяется автопроверка.
      class AmountRangeRule < BaseRule
        BELOW_MINIMUM_REASON = "amount_below_minimum"
        EXCEEDS_LIMIT_REASON = "amount_exceeds_limit"

        def call(provider:, operation:, actuals:)
          return BELOW_MINIMUM_REASON if below_min?(provider, operation)
          return EXCEEDS_LIMIT_REASON if above_max?(provider, operation)

          nil
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
