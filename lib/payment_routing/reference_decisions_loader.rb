module PaymentRouting
  class ReferenceDecisionsLoader
    def initialize(reference_file:)
      @reference_file = reference_file
    end

    def load
      raw = JSON.parse(File.read(@reference_file))

      ReferenceDecisions.new(
        deterministic_cases: raw["deterministic_cases"].map { |c| build_case(c) },
        eligible_providers: raw["eligible_providers"],
        skip_reasons_expected: raw["skip_reasons_expected"]
      )
    end

    private

    def build_case(raw_case)
      ReferenceDecisions::DeterministicCase.new(
        operation_id: raw_case["operation_id"],
        amount: raw_case["amount"],
        bank: raw_case["bank"],
        required_provider: raw_case["required_provider"],
        reason: raw_case["reason"]
      )
    end
  end
end
