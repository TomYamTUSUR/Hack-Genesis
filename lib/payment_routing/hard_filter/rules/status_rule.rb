module PaymentRouting
  module HardFilter
    module Rules
      class StatusRule < BaseRule
        ACTIVE_STATUS = "active"
        REASON = "status_not_active"

        def call(provider:, operation:, actuals:)
          REASON unless provider.status == ACTIVE_STATUS
        end
      end
    end
  end
end
