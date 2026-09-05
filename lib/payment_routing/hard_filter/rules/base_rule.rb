module PaymentRouting
  module HardFilter
    module Rules
      # Интерфейс одной hard-constraint проверки: провайдер либо проходит
      # (call возвращает nil), либо нет (call возвращает REASON - короткий код
      # причины, который Engine кладёт в provider_skip_reasons.reason).
      class BaseRule
        REASON = nil

        def call(provider:, operation:, actuals:)
          raise NotImplementedError, "#{self.class} must implement #call"
        end
      end
    end
  end
end
