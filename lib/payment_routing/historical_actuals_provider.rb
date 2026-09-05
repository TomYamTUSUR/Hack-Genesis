require "time"

module PaymentRouting
  # Считает "фактические" показатели провайдера (count/volume-share, оборот,
  # текущая интенсивность) из таблицы operations_history (db/operations.db),
  # а не из CSV напрямую.
  class HistoricalActualsProvider
    APPROVED_STATUS = "approved"

    def initialize(db:)
      @db = db
    end

    def load
      rows = @db[:operations_history]
             .join(:providers, payment_system_id: :payment_system_id)
             .select(
               Sequel[:providers][:payment_system].as(:payment_system),
               Sequel[:operations_history][:amount].as(:amount),
               Sequel[:operations_history][:status].as(:status),
               Sequel[:operations_history][:created_at].as(:created_at)
             ).all

      # Доля/оборот считаются только по approved - именно они формируют
      # реальную долю/оборот, а не все поданные заявки.
      approved_rows = rows.select { |row| row[:status] == APPROVED_STATUS }
      counts = Hash.new(0)
      volumes = Hash.new(0.0)
      approved_rows.each do |row|
        counts[row[:payment_system]] += 1
        volumes[row[:payment_system]] += row[:amount].to_f
      end
      total_count = counts.values.sum
      total_volume = volumes.values.sum

      rpm_used_by_provider = rpm_used_by_provider(rows)

      # Все провайдеры, не только те, у кого есть approved-история - иначе
      # провайдер без единого approved-платежа выпал бы из результата, а
      # RatingPool#actuals_for упал бы на нём с KeyError при следующем ранжировании.
      @db[:providers].select_map(:payment_system).each_with_object({}) do |payment_system, result|
        result[payment_system] = ProviderActuals.new(
          count_share_actual: MathUtils.percentage_of(counts[payment_system], total_count),
          volume_share_actual: MathUtils.percentage_of(volumes[payment_system], total_volume),
          count_actual: counts[payment_system],
          volume_actual: volumes[payment_system],
          turnover_actual: volumes[payment_system],
          rpm_used: rpm_used_by_provider.fetch(payment_system, Constants::UNDEFINED_UTILIZATION)
        )
      end
    end

    private

    # "Текущая" интенсивность - число заявок ЛЮБОГО статуса за последнюю
    # RPM_WINDOW_SECONDS секунд, отталкиваясь от времени самой поздней
    # операции в истории (а не от реального now: симуляция идёт по данным,
    # а не по часам - окно "сдвигается" вместе с приходом новых операций).
    def rpm_used_by_provider(rows)
      timestamps = rows.filter_map { |row| parse_time(row[:created_at]) }
      return {} if timestamps.empty?

      window_end = timestamps.max
      window_start = window_end - Constants::RPM_WINDOW_SECONDS

      rows.each_with_object(Hash.new(0)) do |row, result|
        created_at = parse_time(row[:created_at])
        next unless created_at && created_at > window_start && created_at <= window_end

        result[row[:payment_system]] += 1
      end
    end

    def parse_time(value)
      Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
