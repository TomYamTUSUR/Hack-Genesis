#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative '../lib/routing_analytics'

project_root = File.expand_path('..', __dir__)
options = {
  providers: File.join(project_root, 'data', 'providers.json'),
  history: File.join(project_root, 'data', 'operations_history.csv'),
  queue: File.join(project_root, 'data', 'operations_queue_10.json'),
  journal: File.join(project_root, 'logs', 'routing_operations.jsonl'),
  output: File.join(project_root, 'reports', 'routing_report.json'),
  stdout: false
}

begin
  protected_roots = [File.join(project_root, 'data'), File.join(project_root, 'scripts')]
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby bin/analyze.rb [options]'
    parser.on('--providers PATH', 'Provider snapshot in providers.json format') { |value| options[:providers] = value }
    parser.on('--history PATH', 'Historical operations in operations_history.csv format') { |value| options[:history] = value }
    parser.on('--queue PATH', 'Pending operations using the queue JSON structure') { |value| options[:queue] = value }
    parser.on('--journal PATH', 'Append-only operation journal in JSONL format') { |value| options[:journal] = value }
    parser.on('--output PATH', 'Destination JSON report') { |value| options[:output] = value }
    parser.on('--stdout', 'Print the report instead of writing it') { options[:stdout] = true }
    parser.on('-h', '--help', 'Show this help') do
      puts parser
      exit 0
    end
  end.parse!

  provider_data = RoutingAnalytics::Loader.providers(options[:providers])
  history_rows = RoutingAnalytics::Loader.history(options[:history])
  pending_operations = RoutingAnalytics::Loader.json_array(options[:queue])
  journal_events = RoutingAnalytics::OperationJournal.new(
    options[:journal],
    protected_roots: protected_roots
  ).read_all
  report = RoutingAnalytics::Analyzer.new(
    provider_data: provider_data,
    history_rows: history_rows,
    journal_events: journal_events,
    pending_operations: pending_operations
  ).report

  if options[:stdout]
    puts JSON.pretty_generate(report)
  else
    RoutingAnalytics::ReportWriter.write(options[:output], report, protected_roots: protected_roots)
    puts "Analytics report written to #{options[:output]}"
  end
rescue OptionParser::ParseError, RoutingAnalytics::Error, Errno::ENOENT => e
  warn "Analytics failed: #{e.message}"
  exit 1
end
