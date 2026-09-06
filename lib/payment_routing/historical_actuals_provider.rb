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

    def load(at: nil)
      rows = @db[:operations_history]
             .join(:providers, payment_system_id: :payment_system_id)
              .select(
                Sequel[:operations_history][:operation_id].as(:operation_id),
               Sequel[:providers][:payment_system].as(:payment_system),
               Sequel[:operations_history][:amount].as(:amount),
               Sequel[:operations_history][:status].as(:status),
               Sequel[:operations_history][:created_at].as(:created_at)
             ).all

      # Доли одобренных выплат считаются среди всех провайдеров, включая fallback.
      approved_rows = rows.select { |row| row[:status] == APPROVED_STATUS }
      counts = Hash.new(0)
      volumes = Hash.new(0.0)
      approved_rows.each do |row|
        counts[row[:payment_system]] += 1
        volumes[row[:payment_system]] += row[:amount].to_f
      end
      total_count = counts.values.sum
      total_volume = volumes.values.sum

      requests = request_times(rows)
      window_end = at || requests.values.flatten.max || Time.now

      # Все провайдеры, не только те, у кого есть approved-история - иначе
      # провайдер без единого approved-платежа выпал бы из результата, а
      # RatingPool#actuals_for упал бы на нём с KeyError при следующем ранжировании.
      @db[:providers].each_with_object({}) do |provider, result|
        payment_system = provider[:payment_system]
        times = requests.fetch(payment_system, [])
        result[payment_system] = ProviderActuals.new(
          count_share_actual: MathUtils.percentage_of(counts[payment_system], total_count),
          volume_share_actual: MathUtils.percentage_of(volumes[payment_system], total_volume),
          count_actual: counts[payment_system],
          volume_actual: volumes[payment_system],
          # Снимок содержит текущий дневной оборот; история может быть неполной
          # и относиться к другим суткам. RunState сбрасывает снимок при смене дня.
          turnover_actual: provider[:daily_approved_amount].to_f,
          rpm_used: times.count { |time| time > window_end - Constants::RPM_WINDOW_SECONDS && time <= window_end },
          request_times: times
        )
      end
    end

    private

    # Новые решения имеют полный журнал обращений (включая технические отказы).
    # Для старой истории без такого журнала одна строка означает одно обращение.
    def request_times(history)
      attempts = if @db.schema(:routing_attempts).any? { |name, _| name == :dispatched_at }
                   @db[:routing_attempts].exclude(dispatched_at: nil)
                     .join(:providers, payment_system_id: :payment_system_id)
                     .select(:operation_id, :payment_system, :dispatched_at).all
                 else
                   []
                 end
      recorded_ids = attempts.to_h { |row| [row[:operation_id], true] }
      result = Hash.new { |hash, key| hash[key] = [] }
      history.each do |row|
        next if recorded_ids[row[:operation_id]]

        time = parse_time(row[:created_at])
        result[row[:payment_system]] << time if time
      end
      attempts.each do |row|
        time = parse_time(row[:dispatched_at])
        result[row[:payment_system]] << time if time
      end
      result
    end

    def parse_time(value)
      return value.to_time if value.respond_to?(:to_time)

      Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
