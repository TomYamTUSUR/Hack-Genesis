module PaymentRouting
  # Фактические показатели провайдера "на сейчас", нужные soft-goal нормам.
  # Сегодня count_share_actual/volume_share_actual/turnover_actual считаются
  # из operations_history.csv (см. HistoricalActualsProvider); в будущем этот
  # же объект будет собираться из БД/рантайм-состояния — интерфейс не изменится.
  #
  # count_share_actual/volume_share_actual — в тех же единицах, что и
  # Provider#traffic_percentage/#volume_share_pct (проценты 0..100).
  # turnover_actual — в тех же единицах, что и Provider#daily_turnover_min (рубли).
  # rpm_used — число запросов провайдеру за последнюю минуту.
  class ProviderActuals
    attr_reader :count_share_actual, :volume_share_actual, :turnover_actual, :rpm_used

    def initialize(count_share_actual:, volume_share_actual:, turnover_actual:, rpm_used:)
      @count_share_actual = count_share_actual
      @volume_share_actual = volume_share_actual
      @turnover_actual = turnover_actual
      @rpm_used = rpm_used
    end
  end
end
