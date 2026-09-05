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
      validate_turnover_bounds!(row)

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
        in_progress_amount_limit: row[:in_progress_amount_limit],
        status: row[:status],
        limit_amount_min: row[:limit_amount_min],
        limit_amount_max: row[:limit_amount_max],
        daily_amount_limit: row[:daily_amount_limit],
        daily_approved_amount: row[:daily_approved_amount],
        available_requisites: row[:available_requisites],
        banks: JSON.parse(row[:banks] || "[]"),
        exclude_banks: row[:exclude_banks],
        provider_margin_pct: row[:provider_margin_pct],
        merchant_margin_pct: row[:merchant_margin_pct],
        allow_negative_agreement: row[:allow_negative_agreement],
        daily_turnover_max: row[:daily_turnover_max],
        avg_latency_sec: row[:avg_latency_sec]
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

    # daily_turnover_min (soft-goal) и daily_turnover_max (hard-constraint,
    # см. описание задания) - согласованные ограничения оборота. Значения
    # приходят из конфигурации бизнеса, а не из data/providers.json, поэтому
    # опечатку в них (отрицательное число, потолок выше daily_amount_limit,
    # min выше max - недостижимое обязательство) нужно ловить сразу при
    # загрузке, а не давать ей молча испортить рейтинг/фильтрацию.
    def validate_turnover_bounds!(row)
      daily_amount_limit = row[:daily_amount_limit]

      { daily_turnover_min: row[:daily_turnover_min], daily_turnover_max: row[:daily_turnover_max] }.each do |field, value|
        next if value.nil?

        raise_turnover_error(row, "#{field} (#{value}) не может быть отрицательным") if value.negative?

        if daily_amount_limit && value > daily_amount_limit
          raise_turnover_error(row, "#{field} (#{value}) не может превышать daily_amount_limit (#{daily_amount_limit})")
        end
      end

      turnover_min = row[:daily_turnover_min]
      turnover_max = row[:daily_turnover_max]
      return unless turnover_min && turnover_max && turnover_min > turnover_max

      raise_turnover_error(row, "daily_turnover_min (#{turnover_min}) не может быть больше daily_turnover_max (#{turnover_max})")
    end

    def raise_turnover_error(row, message)
      raise "Провайдер '#{row[:payment_system]}': #{message}"
    end
  end
end
