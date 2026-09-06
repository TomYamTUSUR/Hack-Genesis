module PaymentRouting
  module HardFilter
    module Rules
      # Проверка "Интенсивность": достгло ли текущее число запросов в минуту (actuals.rpm_used) границу requests_per_minute_limit
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
