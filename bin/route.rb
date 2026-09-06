#!/usr/bin/env ruby
# Обрабатывает очередь операций через Router (hard-constraints -> рейтинг ->
# попытки с fallback -> обновление рантайм-состояния) и сразу же после этого:
#   1. журналирует каждое решение в БД через уже готовый
#      RoutingAnalytics::DatabaseWriter#log_operations (routing_decisions/
#      routing_attempts/eligible_providers/provider_skip_reasons);
#   2. пишет обновлённое рантайм-состояние провайдеров обратно в providers;
#   3. собирает обязательный routing_decisions_test.json из БД (через
#      DecisionsReader - тот же путь, что и отдельный bin/build_decisions.rb,
#      который остаётся самостоятельным скриптом для пересборки JSON без
#      повторного роутинга, если БД уже содержит нужные решения).
#
# Всё это (включая перенос config/business_parameters.yml в БД) выполняется в
# одной db.transaction - при сбое любого из писателей откатывается весь
# прогон целиком, а не только его часть (см. DatabaseWriter#log_operations:
# "Passing the Router's Sequel connection joins its transaction").
#
# OperationQueueLoader сам исключает operation_id, для которых уже есть
# operations_history/routing_decisions - повторный запуск на той же очереди
# без новых операций является штатным идемпотентным no-op, а не ошибкой.
#
# providers/history должны быть уже импортированы (bundle exec ruby bin/import_data.rb).
# Использование: bundle exec ruby bin/route.rb [--database PATH] [--output PATH]

require "json"
require "optparse"
require_relative "../lib/payment_routing"
require_relative "../db/database"
require_relative "../lib/routing_analytics"
require_relative "../lib/payment_routing/importers/business_parameters_importer"

options = {
  database: PaymentRouting::Db::DEFAULT_PATH,
  output: File.join(PaymentRouting.root, "routing_decisions_test.json")
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby bin/route.rb [options]"
  parser.on("--database PATH", "SQLite database (default: db/operations.db)") { |value| options[:database] = value }
  parser.on("--output PATH", "Destination JSON (default: routing_decisions_test.json)") { |value| options[:output] = value }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit 0
  end
end.parse!

include PaymentRouting

config = RoutingConfig.new
db = Db.connect(options[:database])

processed = false

db.transaction do
  Importers::BusinessParametersImporter.new(db: db, business_parameters_file: config.business_parameters_file).import

  rated_and_fallback = config.rated_providers + [config.fallback_provider]
  providers = ProviderRegistry.new(db: db, rated_providers: rated_and_fallback).load
  raise "db/operations.db пуста или в ней нет rated_providers/fallback_provider - запустите bin/import_data.rb" if providers.empty?

  actuals = HistoricalActualsProvider.new(db: db).load
  operations = OperationQueueLoader.new(db: db).load
  next if operations.empty?

  state = Router::RunState.new(providers: providers, actuals_by_provider: actuals)
  strategy_registry = Strategies::StrategyRegistry.new(strategies_file: config.strategies_file)
  router = Router::Router.new(
    state: state,
    rated_payment_systems: config.rated_providers,
    fallback_payment_system: config.fallback_provider,
    strategy_registry: strategy_registry,
    active_strategies: config.active_strategies
  )

  decisions = router.route_all(operations)

  writer = RoutingAnalytics::DatabaseWriter.new(options[:database], db: db)
  operations_by_id = operations.to_h { |operation| [operation.operation_id, { "operation_id" => operation.operation_id, "amount" => operation.amount, "bank" => operation.bank }] }

  Router::StateWriter.new(db: db).write(state)
  writer.log_operations(
    operations: decisions.map { |decision| operations_by_id.fetch(decision.operation_id) },
    decisions: decisions.map(&:to_h)
  )
  writer.close

  processed = true
end

unless processed
  puts "Нет необработанных операций в operations_queue"
  exit 0
end

puts "Состояние провайдеров и решения записаны в БД (providers/routing_decisions/routing_attempts/eligible_providers/provider_skip_reasons)"

decisions_json = DecisionsReader.new(db: db).load
File.write(options[:output], JSON.pretty_generate(decisions_json) + "\n", encoding: "UTF-8")
puts "#{decisions_json.size} решений собрано из БД в #{options[:output]}"
