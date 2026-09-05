module PaymentRouting
  module HardFilter
    module Rules
      # Проверка 4 ("In-progress count/amount", ТЗ 6.4): текущая незавершённая
      # нагрузка провайдера. Count - уже "битком" (>= лимита) исключает независимо
      # от суммы операции; amount учитывает саму операцию, как DailyAmountLimitRule.
      # Оба лимита nil-able - "без ограничения".
      class InProgressRule < BaseRule
        REASON = "in_progress_limit_exceeded"

        def call(provider:, operation:, actuals:)
          REASON if count_exceeded?(provider) || amount_exceeded?(provider, operation)
        end

        private

        def count_exceeded?(provider)
          !provider.in_progress_count_limit.nil? && provider.in_progress_count >= provider.in_progress_count_limit
        end

        def amount_exceeded?(provider, operation)
          return false if provider.in_progress_amount_limit.nil?

          provider.in_progress_amount.to_f + operation.amount > provider.in_progress_amount_limit
        end
      end
    end
  end
end
