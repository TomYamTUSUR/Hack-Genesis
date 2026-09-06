#!/usr/bin/env ruby
# Интерактивное консольное меню поверх движка - альтернатива ручному вызову
# bin/route.rb/bin/import_data.rb/bin/build_report.rb и правке config/*.yml
# руками. Ничего не считает само, только вызывает уже существующие классы.
# Использование: bundle exec ruby bin/menu.rb [--database PATH]

require "fileutils"
require "json"
require "optparse"
require_relative "../lib/payment_routing"
require_relative "../db/database"
require_relative "../lib/routing_analytics"
require_relative "../lib/canonical_database_analytics"
require_relative "../lib/payment_routing/importers/upsert"
require_relative "../lib/payment_routing/importers/provider_lookup"
require_relative "../lib/payment_routing/importers/providers_importer"
require_relative "../lib/payment_routing/importers/business_parameters_importer"
require_relative "../lib/payment_routing/importers/operations_queue_importer"
require_relative "../lib/payment_routing/importers/operations_history_importer"
require_relative "../lib/payment_routing/menu/app"

options = { database: PaymentRouting::Db::DEFAULT_PATH }

OptionParser.new do |parser|
  parser.banner = "Usage: ruby bin/menu.rb [options]"
  parser.on("--database PATH", "SQLite database (default: db/operations.db)") { |value| options[:database] = value }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit 0
  end
end.parse!

PaymentRouting::Menu::App.new(database_path: options[:database]).run
