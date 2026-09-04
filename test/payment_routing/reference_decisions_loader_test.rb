require_relative "../test_helper"

module PaymentRouting
  class ReferenceDecisionsLoaderTest < Minitest::Test
    def setup
      @reference = ReferenceDecisionsLoader.new(reference_file: RoutingConfig.new.reference_decisions_file).load
    end

    def test_parses_deterministic_cases
      op_103 = @reference.deterministic_cases.find { |c| c.operation_id == "op_103" }

      assert_equal "quickpay", op_103.required_provider
      assert_equal 150_000, op_103.amount
    end

    def test_parses_eligible_providers_per_operation
      assert_equal %w[vipay payflow quickpay], @reference.eligible_providers["op_101"]
    end

    def test_parses_skip_reasons_expected_per_operation_and_provider
      assert_equal "bank_not_in_list", @reference.skip_reasons_expected["op_102"]["vipay"]
    end
  end
end
