require_relative "../../lib/payment_routing"
require_relative "../../db/database"
require_relative "../../lib/payment_routing/importers/upsert"
require_relative "../../lib/payment_routing/importers/provider_lookup"
require_relative "../../lib/payment_routing/importers/providers_importer"
require_relative "../../lib/payment_routing/importers/operations_queue_importer"
require_relative "../../lib/payment_routing/importers/operations_history_importer"

module SeededDatabase
  # Стабильный набор из 10 операций для тестов, не зависящий от боевого
  # data/operations_queue_90.json (последний может меняться вместе с задачей).
  QUEUE_FIXTURE = File.expand_path("../fixtures/operations_queue_10.json", __dir__)

  module_function

  def seed(path, providers: true, queue: true, history: true)
    config = PaymentRouting::RoutingConfig.new
    db = PaymentRouting::Db.connect(path)
    PaymentRouting::Db.create_schema!(db)
    PaymentRouting::Importers::ProvidersImporter.new(db: db, providers_file: config.providers_file).import if providers
    PaymentRouting::Importers::OperationsQueueImporter.new(db: db, queue_file: QUEUE_FIXTURE).import if queue
    PaymentRouting::Importers::OperationsHistoryImporter.new(db: db, history_file: config.operations_history_file).import if history
    db.disconnect
    path
  end
end
