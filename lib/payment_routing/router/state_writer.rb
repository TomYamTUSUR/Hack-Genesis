module PaymentRouting
  module Router
    # Пишет финальное состояние RunState обратно в таблицу providers - без
    # этого шага изменения (in_progress_count/amount, daily_approved_amount),
    # накопленные MetricsUpdater за время прогона, видны только внутри
    # процесса и теряются к следующему запуску bin/route.rb.
    #
    # count_share_actual/volume_share_actual/turnover_actual/rpm_used в БД не
    # пишутся - это не колонки providers, а производные "фактические"
    # показатели, каждый раз заново считаемые HistoricalActualsProvider из
    # operations_history.
    class StateWriter
      def initialize(db:)
        @db = db
      end

      def write(state)
        state.providers.each do |provider|
          @db[:providers].where(payment_system: provider.payment_system).update(
            in_progress_count: provider.in_progress_count,
            in_progress_amount: provider.in_progress_amount,
            daily_approved_amount: provider.daily_approved_amount
          )
        end
      end
    end
  end
end
