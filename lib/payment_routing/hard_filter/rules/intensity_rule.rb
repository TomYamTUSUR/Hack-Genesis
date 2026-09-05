module PaymentRouting
  module HardFilter
    module Rules
      # Проверка 8 ("Интенсивность", ТЗ 6.8): rate limit провайдера уже
      # исчерпан, если текущее число запросов в минуту (actuals.rpm_used, см.
      # HistoricalActualsProvider) достигло requests_per_minute_limit - при
      # 7 из 7 обращений за минуту 8-е уже не должно пройти, поэтому >=, а не >.
      # Лимит nil - ограничения нет.
      class IntensityRule < BaseRule
        REASON = "rate_limit_exceeded"

        def call(provider:, operation:, actuals:)
          return nil if provider.requests_per_minute_limit.nil?

          REASON if actuals.rpm_used >= provider.requests_per_minute_limit
        end
      end
    end
  end
end
