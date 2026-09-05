module PaymentRouting
  # Фактические показатели провайдера "на сейчас", нужные soft-goal нормам.
  # Сегодня все четыре поля считаются агрегацией по operations_history в БД
  # (см. HistoricalActualsProvider); когда появится рантайм-состояние
  # (обновляемое после каждой обработанной операции, а не только из истории),
  # источник сменится, а этот интерфейс — нет.
  #
  # count_share_actual/volume_share_actual — в тех же единицах, что и
  # Provider#traffic_percentage/#volume_share_pct (проценты 0..100).
  # turnover_actual — в тех же единицах, что и Provider#daily_turnover_min (рубли).
  # rpm_used — число заявок провайдеру за последнюю минуту истории (любого статуса).
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
