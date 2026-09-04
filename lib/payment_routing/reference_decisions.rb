module PaymentRouting
  # Эталон из data/reference_decisions.json - используется для самопроверки
  # hard-constraints (см. описание файла: "единственный допустимый провайдер",
  # "eligible_providers", "skip_reasons_expected"), пока нет validate.rb.
  class ReferenceDecisions
    DeterministicCase = Struct.new(:operation_id, :amount, :bank, :required_provider, :reason, keyword_init: true)

    attr_reader :deterministic_cases, :eligible_providers, :skip_reasons_expected

    def initialize(deterministic_cases:, eligible_providers:, skip_reasons_expected:)
      @deterministic_cases = deterministic_cases
      @eligible_providers = eligible_providers
      @skip_reasons_expected = skip_reasons_expected
    end
  end
end
