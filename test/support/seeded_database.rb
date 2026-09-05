require_relative "../../lib/payment_routing"
require_relative "../../db/database"
require_relative "../../lib/payment_routing/importers/upsert"
require_relative "../../lib/payment_routing/importers/provider_lookup"
require_relative "../../lib/payment_routing/importers/providers_importer"
require_relative "../../lib/payment_routing/importers/operations_queue_importer"
require_relative "../../lib/payment_routing/importers/operations_history_importer"

# Строит файловую БД из data/* тем же путём, что и bin/import_data.rb - для
# тестов lib/routing_analytics.rb и lib/canonical_database_analytics.rb,
# которым (в отличие от PaymentRouting::TestFactories.seeded_db) нужен путь к
# реальному файлу на диске, а не in-memory соединение.
module SeededDatabase
  module_function

  def seed(path, providers: true, queue: true, history: true)
    config = PaymentRouting::RoutingConfig.new
    db = PaymentRouting::Db.connect(path)
    PaymentRouting::Db.create_schema!(db)
    PaymentRouting::Importers::ProvidersImporter.new(db: db, providers_file: config.providers_file).import if providers
    PaymentRouting::Importers::OperationsQueueImporter.new(db: db, queue_file: config.operations_queue_file).import if queue
    PaymentRouting::Importers::OperationsHistoryImporter.new(db: db, history_file: config.operations_history_file).import if history
    db.disconnect
    path
  end
end
