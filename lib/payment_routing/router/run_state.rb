module PaymentRouting
  module Router
    #Модуль обновления данных провадеров, в ходе обработки очереди
    class RunState
      attr_reader :time

      def initialize(providers:, actuals_by_provider:)
        @providers_by_name = providers.to_h { |provider| [provider.payment_system, provider] }
        @actuals_by_name = actuals_by_provider.dup
      end

      def provider(payment_system)
        @providers_by_name.fetch(payment_system)
      end

      def providers
        @providers_by_name.values
      end

      def actuals(payment_system)
        @actuals_by_name.fetch(payment_system)
      end

      def actuals_by_provider
        @actuals_by_name
      end

      def replace_provider(provider)
        @providers_by_name[provider.payment_system] = provider
      end

      def replace_actuals(payment_system, actuals)
        @actuals_by_name[payment_system] = actuals
      end

      def advance_to(time)
        raise ArgumentError, "operation time moved backwards" if @time && time < @time

        @time = time
        providers.each do |provider|
          day = time.getlocal(provider.daily_utc_offset).strftime("%Y-%m-%d")
          previous_day = provider.daily_approved_date
          if previous_day && day < previous_day
            raise ArgumentError, "operation precedes daily snapshot for #{provider.payment_system}"
          end
          amount = previous_day && day > previous_day ? 0 : provider.daily_approved_amount.to_f
          replace_provider(provider.with(daily_approved_date: day, daily_approved_amount: amount))
          current = actuals(provider.payment_system)
          replace_actuals(provider.payment_system, current.with(turnover_actual: amount))
        end
        @actuals_by_name.keys.each do |name|
          current = actuals(name)
          times = current.request_times || Array.new(current.rpm_used.to_i, time)
          times = times.select { |at| at > time - Constants::RPM_WINDOW_SECONDS }
          replace_actuals(name, current.with(request_times: times, rpm_used: times.count { |at| at <= time }))
        end
      end

      def record_request(payment_system)
        current = actuals(payment_system)
        times = (current.request_times || []) + [time]
        replace_actuals(payment_system, current.with(request_times: times, rpm_used: current.rpm_used + 1))
      end
    end
  end
end
