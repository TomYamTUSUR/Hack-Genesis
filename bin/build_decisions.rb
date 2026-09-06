#!/usr/bin/env ruby

require "json"
require "optparse"
require_relative "../lib/payment_routing"
require_relative "../db/database"

options = {
  database: PaymentRouting::Db::DEFAULT_PATH,
  output: File.join(PaymentRouting.root, "routing_decisions_test.json")
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby bin/build_decisions.rb [options]"
  parser.on("--database PATH", "SQLite database (default: db/operations.db)") { |value| options[:database] = value }
  parser.on("--output PATH", "Destination JSON (default: routing_decisions_test.json)") { |value| options[:output] = value }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit 0
  end
end.parse!

db = PaymentRouting::Db.connect(options[:database])
decisions = PaymentRouting::DecisionsReader.new(db: db).load

File.write(options[:output], JSON.pretty_generate(decisions) + "\n", encoding: "UTF-8")
puts "#{decisions.size} решений собрано из БД в #{options[:output]}"
