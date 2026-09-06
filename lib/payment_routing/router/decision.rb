module PaymentRouting
  module Router
    Attempt = Struct.new(:provider, :decision, :reason, :details, :dispatched_at, keyword_init: true) do
      def to_h
        result = { "provider" => provider, "decision" => decision, "reason" => reason }
        result["details"] = details if details
        result["dispatched_at"] = dispatched_at.iso8601(6) if dispatched_at
        result
      end
    end

    class Decision
      attr_reader :operation_id, :selected_provider, :attempts, :simulated_result, :latency_sec, :explanation

      def initialize(operation_id:, selected_provider:, attempts:, simulated_result:, latency_sec:, explanation: nil)
        @operation_id = operation_id
        @selected_provider = selected_provider
        @attempts = attempts
        @simulated_result = simulated_result
        @latency_sec = latency_sec
        @explanation = explanation
      end

      def to_h
        result = {
          "operation_id" => operation_id,
          "selected_provider" => selected_provider,
          "attempts" => attempts.map(&:to_h),
          "simulated_result" => simulated_result,
          "latency_sec" => latency_sec
        }
        result["explanation"] = explanation if explanation
        result
      end
    end
  end
end
