module PaymentRouting
  module Router
    # Пишет финальное состояние параметров обратно в таблицу providers
    class StateWriter
      def initialize(db:)
        @db = db
      end

      def write(state)
        @db.transaction do
          state.providers.each do |provider|
            @db[:providers].where(payment_system: provider.payment_system).update(
              in_progress_count: provider.in_progress_count,
              in_progress_amount: provider.in_progress_amount,
              daily_approved_amount: provider.daily_approved_amount,
              daily_approved_date: provider.daily_approved_date,
              daily_utc_offset: provider.daily_utc_offset
            )
          end
        end
      end
    end
  end
end
