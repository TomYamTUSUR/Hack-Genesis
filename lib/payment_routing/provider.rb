module PaymentRouting
  # Провайдер как его видят блок стратегий/рейтинга: статические параметры из
  # providers.json (снимок состояния) и config/providers_overlay.yml (бизнес-политика).
  # Hard-constraint-специфичные поля (banks, margins, available_requisites, ...)
  # сюда намеренно не включены — они появятся вместе с блоком hard-constraints.
  class Provider
    attr_reader :payment_system, :priority, :conversion_24h,
                :traffic_percentage, :volume_share_pct,
                :preferred_range, :requests_per_minute_limit, :daily_turnover_min,
                :in_progress_count, :in_progress_count_limit,
                :in_progress_amount, :in_progress_amount_limit

    def initialize(payment_system:, priority:, conversion_24h:, traffic_percentage:,
                   volume_share_pct:, preferred_range:, requests_per_minute_limit:,
                   daily_turnover_min:, in_progress_count:, in_progress_count_limit:,
                   in_progress_amount:, in_progress_amount_limit:)
      @payment_system = payment_system
      @priority = priority
      @conversion_24h = conversion_24h
      @traffic_percentage = traffic_percentage
      @volume_share_pct = volume_share_pct
      @preferred_range = preferred_range
      @requests_per_minute_limit = requests_per_minute_limit
      @daily_turnover_min = daily_turnover_min
      @in_progress_count = in_progress_count
      @in_progress_count_limit = in_progress_count_limit
      @in_progress_amount = in_progress_amount
      @in_progress_amount_limit = in_progress_amount_limit
    end
  end
end
