#!/usr/bin/env ruby

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

result = RoutingRun.new(db: db, database_path: options[:database], config: config).call

unless result.processed
  puts "Нет необработанных операций в operations_queue"
  exit 0
end

puts "Состояние провайдеров и решения записаны в БД (providers/routing_decisions/routing_attempts/eligible_providers/provider_skip_reasons)"

File.write(options[:output], JSON.pretty_generate(result.decisions) + "\n", encoding: "UTF-8")
puts "#{result.decisions.size} решений собрано из БД в #{options[:output]}"
