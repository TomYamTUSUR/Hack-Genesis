module PaymentRouting
  module Router
    # Одна запись в attempts итогового решения - формат из ТЗ ("Формат
    # результата роутинга"): provider, decision (selected/skipped), reason.
    Attempt = Struct.new(:provider, :decision, :reason, keyword_init: true) do
      def to_h
        { "provider" => provider, "decision" => decision, "reason" => reason }
      end
    end

    # Итоговое решение по одной операции - ровно то, что требует ТЗ и что
    # понимает RoutingAnalytics::DatabaseWriter#log_operations (тот же набор
    # строковых ключей в to_h).
    class Decision
      attr_reader :operation_id, :selected_provider, :attempts, :simulated_result, :latency_sec

      def initialize(operation_id:, selected_provider:, attempts:, simulated_result:, latency_sec:)
        @operation_id = operation_id
        @selected_provider = selected_provider
        @attempts = attempts
        @simulated_result = simulated_result
        @latency_sec = latency_sec
      end

      def to_h
        {
          "operation_id" => operation_id,
          "selected_provider" => selected_provider,
          "attempts" => attempts.map(&:to_h),
          "simulated_result" => simulated_result,
          "latency_sec" => latency_sec
        }
      end
    end
  end
end
