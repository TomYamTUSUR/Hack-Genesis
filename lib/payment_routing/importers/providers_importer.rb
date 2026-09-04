require "json"

module PaymentRouting
  module Importers
    # Читает data/providers.json 1:1 в таблицу providers. Поля, которых нет в
    # файле (volume_share_pct, requests_per_minute_limit, daily_turnover_min/max),
    # этот импортёр не трогает вовсе - они остаются как есть (null при первой
    # вставке), их дополняет отдельный блок, а не парсер.
    class ProvidersImporter
      def initialize(db:, providers_file:)
        @db = db
        @providers_file = providers_file
      end

      def import
        raw_providers = JSON.parse(File.read(@providers_file))["providers"]
        raw_providers.each { |raw| Upsert.by_key(@db[:providers], :payment_system, raw["payment_system"], attrs_for(raw)) }
        raw_providers.size
      end

      private

      def attrs_for(raw)
        {
          payment_system: raw["payment_system"],
          status: raw["status"],
          traffic_percentage: raw["traffic_percentage"],
          priority: raw["priority"],
          limit_amount_min: raw["limit_amount_min"],
          limit_amount_max: raw["limit_amount_max"],
          daily_amount_limit: raw["daily_amount_limit"],
          daily_approved_amount: raw["daily_approved_amount"],
          in_progress_count_limit: raw["in_progress_count_limit"],
          in_progress_count: raw["in_progress_count"],
          in_progress_amount_limit: raw["in_progress_amount_limit"],
          in_progress_amount: raw["in_progress_amount"],
          available_requisites: raw["available_requisites"],
          conversion_24h: raw["conversion_24h"],
          avg_latency_sec: raw["avg_latency_sec"],
          banks: JSON.generate(raw["banks"] || []),
          exclude_banks: raw["exclude_banks"],
          provider_margin_pct: raw["provider_margin_pct"],
          merchant_margin_pct: raw["merchant_margin_pct"],
          allow_negative_agreement: raw["allow_negative_agreement"],
          note: raw["note"]
        }
      end
    end
  end
end
