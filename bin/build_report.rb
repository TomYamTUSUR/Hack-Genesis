#!/usr/bin/env ruby
# Строит обязательный routing_report_test.json из результатов реального
# прогона (запустите bin/route.rb перед этим) - переиспользует уже готовый
# RoutingAnalytics::CanonicalDatabaseAnalytics (bin/analyze_db.rb), просто
# кладёт отчёт под требуемым именем в корень репозитория.
# Использование: bundle exec ruby bin/build_report.rb [--database PATH] [--output PATH]

require "optparse"
require_relative "../lib/canonical_database_analytics"
require_relative "../lib/payment_routing"
require_relative "../db/database"

options = {
  database: PaymentRouting::Db::DEFAULT_PATH,
  output: File.join(PaymentRouting.root, "routing_report_test.json")
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby bin/build_report.rb [options]"
  parser.on("--database PATH", "SQLite database (default: db/operations.db)") { |value| options[:database] = value }
  parser.on("--output PATH", "Destination JSON (default: routing_report_test.json)") { |value| options[:output] = value }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit 0
  end
end.parse!

analytics = RoutingAnalytics::CanonicalDatabaseAnalytics.new(options[:database])
report = analytics.report
RoutingAnalytics::ReportWriter.write(options[:output], report)
puts "Отчёт записан в #{options[:output]}"
analytics.close
