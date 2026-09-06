module PaymentRouting
  module HardFilter
    module Rules
      # Интерфейс одной hard-constraint проверки + возврат причины, если не подходит
      class BaseRule
        REASON = nil

        def call(provider:, operation:, actuals:)
          raise NotImplementedError, "#{self.class} must implement #call"
        end
      end
    end
  end
end
