require "csv"

module PaymentRouting
  # Считает "фактические" показатели провайдера (count/volume-share, оборот) из
  # data/operations_history.csv. Учитываются только approved-операции - именно они
  # формируют реальную долю/оборот, а не все поданные заявки.
  #
  # rpm_used в истории не восстановить (это скользящее окно "прямо сейчас",
  # а не агрегат за день) - до появления рантайм rate-limiter'а отдаётся 0
  # через Constants::UNDEFINED_UTILIZATION.
  class HistoricalActualsProvider
    APPROVED_STATUS = "approved"

    def initialize(history_file:)
      @history_file = history_file
    end

    def load
      approved_rows = CSV.read(@history_file, headers: true).select { |row| row["status"] == APPROVED_STATUS }

      counts = Hash.new(0)
      volumes = Hash.new(0.0)
      approved_rows.each do |row|
        counts[row["payment_system"]] += 1
        volumes[row["payment_system"]] += row["amount"].to_f
      end

      total_count = counts.values.sum
      total_volume = volumes.values.sum

      counts.keys.each_with_object({}) do |payment_system, result|
        result[payment_system] = ProviderActuals.new(
          count_share_actual: percentage_of(counts[payment_system], total_count),
          volume_share_actual: percentage_of(volumes[payment_system], total_volume),
          turnover_actual: volumes[payment_system],
          rpm_used: Constants::UNDEFINED_UTILIZATION
        )
      end
    end

    private

    def percentage_of(part, total)
      return 0.0 if total.zero?

      100.0 * part / total
    end
  end
end
