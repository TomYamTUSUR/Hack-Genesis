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
# providers/history должны быть уже импортированы (bundle exec ruby bin/import_data.rb).
# Использование: bundle exec ruby bin/route.rb [--database PATH]

require "optparse"
require_relative "../lib/payment_routing"
require_relative "../db/database"
require_relative "../lib/routing_analytics"

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

rated_and_fallback = config.rated_providers + [config.fallback_provider]
providers = ProviderRegistry.new(db: db, rated_providers: rated_and_fallback).load
raise "db/operations.db пуста или в ней нет rated_providers/fallback_provider - запустите bin/import_data.rb" if providers.empty?

actuals = HistoricalActualsProvider.new(db: db).load
operations = OperationQueueLoader.new(db: db).load
raise "operations_queue пуста - нечего обрабатывать" if operations.empty?

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

Router::StateWriter.new(db: db).write(state)
puts "Состояние провайдеров (in_progress_count/amount, daily_approved_amount) обновлено в БД"

writer = RoutingAnalytics::DatabaseWriter.new(options[:database])
operations_by_id = operations.to_h { |operation| [operation.operation_id, { "operation_id" => operation.operation_id, "amount" => operation.amount, "bank" => operation.bank }] }
writer.log_operations(
  operations: decisions.map { |decision| operations_by_id.fetch(decision.operation_id) },
  decisions: decisions.map(&:to_h)
)
writer.close
puts "Решения записаны в БД (routing_decisions/routing_attempts/eligible_providers/provider_skip_reasons)"
puts "Запустите bin/build_decisions.rb, чтобы собрать routing_decisions_test.json из БД"
