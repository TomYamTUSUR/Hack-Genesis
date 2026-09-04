module PaymentRouting
  # Собирает Provider из двух источников: data/providers.json (снимок состояния)
  # и config/providers_overlay.yml (бизнес-политика, см. Constants и docs).
  #
  # В рейтинге участвуют только провайдеры, для которых задан оверлей -
  # self-provider (fallback) политику стратегий не имеет и в этот список не должен попадать,
  # поэтому явно перечислять его имя в коде не нужно: список провайдеров определяется конфигом.
  class ProviderRegistry
    def initialize(providers_file:, overlay_file:)
      @providers_file = providers_file
      @overlay_file = overlay_file
    end

    def load
      overlay_by_system = load_overlay
      raw_providers = JSON.parse(File.read(@providers_file))["providers"]

      raw_providers.filter_map do |raw|
        overlay = overlay_by_system[raw["payment_system"]]
        next unless overlay

        build_provider(raw, overlay)
      end
    end

    private

    def load_overlay
      YAML.safe_load(File.read(@overlay_file))["providers"]
    end

    def build_provider(raw, overlay)
      Provider.new(
        payment_system: raw["payment_system"],
        priority: raw["priority"],
        conversion_24h: raw["conversion_24h"],
        traffic_percentage: raw["traffic_percentage"],
        volume_share_pct: overlay["volume_share_pct"],
        preferred_range: AmountRange.new(**overlay["preferred_range"].transform_keys(&:to_sym)),
        requests_per_minute_limit: overlay["requests_per_minute_limit"],
        daily_turnover_min: overlay["daily_turnover_min"],
        in_progress_count: raw["in_progress_count"],
        in_progress_count_limit: raw["in_progress_count_limit"],
        in_progress_amount: raw["in_progress_amount"],
        in_progress_amount_limit: raw["in_progress_amount_limit"]
      )
    end
  end
end
