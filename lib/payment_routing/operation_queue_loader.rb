module PaymentRouting
  # Строит [Operation] из таблицы operations_queue (db/operations.db) -
  # единственный путь превращения заявки в доменный объект для strategies/rating
  # и будущего Router'а. Файлы не читает.
  class OperationQueueLoader
    def initialize(db:)
      @db = db
    end

    def load
      @db[:operations_queue]
        .exclude(operation_id: @db[:routing_decisions].select(:operation_id))
        .exclude(operation_id: @db[:operations_history].select(:operation_id))
        .map do |row|
        Operation.new(operation_id: row[:operation_id], amount: row[:amount], bank: row[:bank],
                      created_at: row[:created_at], card_brand: row[:card_brand])
      end.sort_by { |operation| [operation.created_at, operation.operation_id] }
    end
  end
end
