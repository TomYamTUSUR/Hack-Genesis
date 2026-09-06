module PaymentRouting
  module HardFilter
    module Rules
      class BaseRule
        REASON = nil

        def call(provider:, operation:, actuals:)
          raise NotImplementedError, "#{self.class} must implement #call"
        end
      end
    end
  end
end
