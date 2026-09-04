module PaymentRouting
  # Строит [Provider] из таблицы providers (db/operations.db) - единственный
  # источник данных о провайдерах для strategies/rating, файлы не читает.
  #
  # rated_providers - явный список payment_system, которые вообще участвуют
  # в рейтинге (self-provider/fallback туда не входит - см. config/routing.yml).
  class ProviderRegistry
    def initialize(db:, rated_providers:)
      @db = db
      @rated_providers = rated_providers
    end

    def load
      @db[:providers].where(payment_system: @rated_providers).map { |row| build_provider(row) }
    end

    private

    def build_provider(row)
      Provider.new(
        payment_system: row[:payment_system],
        priority: row[:priority],
        conversion_24h: row[:conversion_24h],
        traffic_percentage: row[:traffic_percentage],
        volume_share_pct: row[:volume_share_pct],
        preferred_range: preferred_range_for(row),
        requests_per_minute_limit: row[:requests_per_minute_limit],
        daily_turnover_min: row[:daily_turnover_min],
        in_progress_count: row[:in_progress_count],
        in_progress_count_limit: row[:in_progress_count_limit],
        in_progress_amount: row[:in_progress_amount],
        in_progress_amount_limit: row[:in_progress_amount_limit]
      )
    end

    # preferred_range_min/max - приоритетный диапазон для стратегии "по сумме
    # чека" (см. Rating::Norms::RangeFitNorm). limit_amount_min/max сюда не
    # подставляется - это отдельный hard-constraint (допуск провайдера к
    # операции), а не ориентир для рейтинга. Пока preferred_range не заполнен
    # (null) - у провайдера просто нет предпочтения по сумме (RangeFitNorm
    # относится к этому нейтрально).
    def preferred_range_for(row)
      return nil if row[:preferred_range_min].nil? || row[:preferred_range_max].nil?

      AmountRange.new(min: row[:preferred_range_min], max: row[:preferred_range_max])
    end
  end
end
