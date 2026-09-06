module PaymentRouting
  module HardFilter
    module Rules
      class MarginRule < BaseRule
        REASON = "margin_not_acceptable"

        def call(provider:, operation:, actuals:)
          return nil if provider.allow_negative_agreement
          return nil if provider.provider_margin_pct.nil? || provider.merchant_margin_pct.nil?

          REASON if provider.provider_margin_pct > provider.merchant_margin_pct
        end
      end
    end
  end
end
