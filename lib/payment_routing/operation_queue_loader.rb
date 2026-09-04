module PaymentRouting
  # Разбирает data/operations_queue_10.json (и, позже, operations_queue_test.json)
  # в [Operation] - единственный путь превращения "сырой" заявки в доменный
  # объект, которым уже пользуются strategies/rating и будущий Router.
  class OperationQueueLoader
    def initialize(queue_file:)
      @queue_file = queue_file
    end

    def load
      JSON.parse(File.read(@queue_file)).map do |raw|
        Operation.new(operation_id: raw["operation_id"], amount: raw["amount"], bank: raw["bank"])
      end
    end
  end
end
