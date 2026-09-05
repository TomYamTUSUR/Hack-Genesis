require_relative "../../test_helper"

module PaymentRouting
  module Router
    class DecisionTest < Minitest::Test
      def test_to_h_matches_the_output_format_from_the_task
        decision = Decision.new(
          operation_id: "op_103",
          selected_provider: "quickpay",
          attempts: [
            Attempt.new(provider: "vipay", decision: "skipped", reason: "amount_exceeds_limit"),
            Attempt.new(provider: "quickpay", decision: "selected", reason: "only_eligible_provider")
          ],
          simulated_result: "approved",
          latency_sec: 28
        )

        assert_equal(
          {
            "operation_id" => "op_103",
            "selected_provider" => "quickpay",
            "attempts" => [
              { "provider" => "vipay", "decision" => "skipped", "reason" => "amount_exceeds_limit" },
              { "provider" => "quickpay", "decision" => "selected", "reason" => "only_eligible_provider" }
            ],
            "simulated_result" => "approved",
            "latency_sec" => 28
          },
          decision.to_h
        )
      end
    end
  end
end
