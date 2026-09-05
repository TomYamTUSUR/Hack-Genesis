module PaymentRouting
  module HardFilter
    module Rules
      # Проверка 8 ("Интенсивность", ТЗ 6.8): rate limit провайдера превышен,
      # если текущее число запросов в минуту (actuals.rpm_used, см.
      # HistoricalActualsProvider) уже строго больше requests_per_minute_limit.
      # Лимит nil - ограничения нет.
      class IntensityRule < BaseRule
        REASON = "rate_limit_exceeded"

        def call(provider:, operation:, actuals:)
          return nil if provider.requests_per_minute_limit.nil?

          REASON if actuals.rpm_used > provider.requests_per_minute_limit
        end
      end
    end
  end
end
