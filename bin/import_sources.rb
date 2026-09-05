#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative '../lib/routing_analytics'

project_root = File.expand_path('..', __dir__)
options = {
  database: File.join(project_root, 'DB', 'operations.db'),
  providers: File.join(project_root, 'data', 'providers.json'),
  history: File.join(project_root, 'data', 'operations_history.csv'),
  queue: File.join(project_root, 'data', 'operations_queue_10.json'),
  references: File.join(project_root, 'data', 'reference_decisions.json')
}
writer = nil

begin
  protected_roots = [File.join(project_root, 'data'), File.join(project_root, 'scripts')]
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby bin/import_sources.rb [options]'
    parser.on('--database PATH', 'Destination SQLite database') { |value| options[:database] = value }
    parser.on('--providers PATH', 'Provider snapshot JSON') { |value| options[:providers] = value }
    parser.on('--history PATH', 'Historical operations CSV') { |value| options[:history] = value }
    parser.on('--queue PATH', 'Pending operations JSON') { |value| options[:queue] = value }
    parser.on('--references PATH', 'Reference decisions JSON') { |value| options[:references] = value }
    parser.on('-h', '--help', 'Show this help') do
      puts parser
      exit 0
    end
  end.parse!

  writer = RoutingAnalytics::DatabaseWriter.new(options[:database], protected_roots: protected_roots)
  counts = writer.import_sources(
    provider_data: RoutingAnalytics::Loader.providers(options[:providers]),
    history_rows: RoutingAnalytics::Loader.history(options[:history]),
    queue_operations: RoutingAnalytics::Loader.json_array(options[:queue]),
    reference_data: RoutingAnalytics::Loader.json_value(options[:references])
  )
  puts "Imported metadata=#{counts[:metadata]} providers=#{counts[:providers]} history=#{counts[:history]} " \
       "queue=#{counts[:queue]} references=#{counts[:references]} into #{options[:database]}"
rescue OptionParser::ParseError, RoutingAnalytics::Error, Errno::ENOENT => e
  warn "Database import failed: #{e.message}"
  exit 1
ensure
  writer&.close
end
