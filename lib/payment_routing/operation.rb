module PaymentRouting
  # Заявка на выплату — из блока стратегий/рейтинга её интересует только сумма
  # (для range_fit). Банк/реквизиты нужны только hard-constraints.
  class Operation
    attr_reader :operation_id, :amount

    def initialize(operation_id:, amount:)
      @operation_id = operation_id
      @amount = amount.to_f
    end
  end
end
