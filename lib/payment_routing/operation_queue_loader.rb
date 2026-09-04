module PaymentRouting
  # Строит [Operation] из таблицы operations_queue (db/operations.db) -
  # единственный путь превращения заявки в доменный объект для strategies/rating
  # и будущего Router'а. Файлы не читает.
  class OperationQueueLoader
    def initialize(db:)
      @db = db
    end

    def load
      @db[:operations_queue].map do |row|
        Operation.new(operation_id: row[:operation_id], amount: row[:amount], bank: row[:bank])
      end
    end
  end
end
