module PaymentRouting
  # Заявка на выплату. Блоку стратегий/рейтинга из неё нужна только сумма (для
  # range_fit); bank нужен hard-constraints (банковский фильтр, не реализован
  # ещё) - опционален здесь, чтобы существующий код без него не ломался.
  class Operation
    attr_reader :operation_id, :amount, :bank

    def initialize(operation_id:, amount:, bank: nil)
      @operation_id = operation_id
      @amount = amount.to_f
      @bank = bank
    end
  end
end
