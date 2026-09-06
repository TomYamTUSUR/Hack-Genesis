#!/usr/bin/env ruby
# Обрабатывает очередь операций через Router (hard-constraints -> рейтинг ->
# попытки с fallback -> обновление рантайм-состояния) и:
#   1. журналирует каждое решение в БД через уже готовый
#      RoutingAnalytics::DatabaseWriter#log_operations (routing_decisions/
#      routing_attempts/eligible_providers/provider_skip_reasons);
#   2. пишет обновлённое рантайм-состояние провайдеров обратно в providers.
# Сам routing_decisions_test.json этот скрипт не пишет - его собирает из БД
# bin/build_decisions.rb (тем же принципом, что bin/build_report.rb собирает
# routing_report_test.json), запускать сразу после этого скрипта.
#
# Перед чтением providers всегда переносит config/business_parameters.yml в БД
# (BusinessParametersImporter) - Router читает только БД (см. README), а этот
# шаг гарантирует, что она не может "отстать" от файла: не нужно отдельно
# помнить про `bin/import_data.rb business_parameters` после правки YAML.
#
# providers/history должны быть уже импортированы (bundle exec ruby bin/import_data.rb).
# Использование: bundle exec ruby bin/route.rb [--database PATH]

require "optparse"
require_relative "../lib/payment_routing"
require_relative "../db/database"
require_relative "../lib/routing_analytics"
require_relative "../lib/payment_routing/importers/business_parameters_importer"

options = { database: PaymentRouting::Db::DEFAULT_PATH }

OptionParser.new do |parser|
  parser.banner = "Usage: ruby bin/route.rb [options]"
  parser.on("--database PATH", "SQLite database (default: db/operations.db)") { |value| options[:database] = value }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit 0
  end
end.parse!

include PaymentRouting

config = RoutingConfig.new
db = Db.connect(options[:database])

decisions = []
begin
  # Lock before loading pending IDs and state; a second runner sees the committed
  # result and cannot dispatch the same queue again.
  db.transaction(mode: :immediate) do
    Db.upgrade_schema!(db)
    operations = OperationQueueLoader.new(db: db).load
    next if operations.empty?

    Importers::BusinessParametersImporter.new(db: db, business_parameters_file: config.business_parameters_file).import
    names = config.rated_providers + [config.fallback_provider]
    providers = ProviderRegistry.new(db: db, rated_providers: names).load
    raise "db/operations.db пуста или в ней нет rated_providers/fallback_provider - запустите bin/import_data.rb" if providers.empty?

    actuals = HistoricalActualsProvider.new(db: db).load(at: operations.first.created_at)
    state = Router::RunState.new(providers: providers, actuals_by_provider: actuals)
    router = Router::Router.new(
      state: state, rated_payment_systems: config.rated_providers,
      fallback_payment_system: config.fallback_provider,
      strategy_registry: Strategies::StrategyRegistry.new(strategies_file: config.strategies_file),
      active_strategies: config.active_strategies
    )
    decisions = router.route_all(operations)
    Router::StateWriter.new(db: db).write(state)
    writer = RoutingAnalytics::DatabaseWriter.new(options[:database], db: db)
    writer.log_operations(operations: operations.map(&:to_h), decisions: decisions.map(&:to_h))
  end
  if decisions.empty?
    puts "Нет необработанных операций"
  else
    puts "Решения (#{decisions.size}) и состояние провайдеров сохранены в БД"
    puts "Запустите bin/build_decisions.rb, чтобы собрать routing_decisions_test.json из БД"
  end
ensure
  db.disconnect
end
