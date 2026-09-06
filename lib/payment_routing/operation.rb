require "time"

module PaymentRouting
  # Заявка на выплату. Блоку стратегий/рейтинга из неё нужна только сумма (для
  # range_fit); bank нужен hard-constraints (банковский фильтр, не реализован
  # ещё) - опционален здесь, чтобы существующий код без него не ломался.
  class Operation
    attr_reader :operation_id, :amount, :bank, :created_at, :card_brand

    def initialize(operation_id:, amount:, bank: nil, created_at: nil, card_brand: nil)
      @operation_id = operation_id
      @amount = amount.to_f
      @bank = bank
      @created_at = if created_at.respond_to?(:to_time)
                      created_at.to_time
                    elsif created_at
                      Time.parse(created_at.to_s)
                    end
      @card_brand = card_brand
    end

    def to_h
      {
        "operation_id" => operation_id, "amount" => amount, "bank" => bank,
        "created_at" => created_at&.iso8601(6), "card_brand" => card_brand
      }
    end
  end
end
