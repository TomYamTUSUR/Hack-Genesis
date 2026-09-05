module PaymentRouting
  module HardFilter
    module Rules
      # Проверка 6 ("Маржа", ТЗ 6.6): провайдер не должен запрашивать маржу выше
      # мерчантской, если только договор явно не разрешает это
      # (allow_negative_agreement: true снимает проверку целиком).
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
