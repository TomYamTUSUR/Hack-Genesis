#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative '../lib/routing_analytics'

project_root = File.expand_path('..', __dir__)
options = {
  journal: File.join(project_root, 'logs', 'routing_operations.jsonl')
}

begin
  protected_roots = [File.join(project_root, 'data'), File.join(project_root, 'scripts')]
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby bin/log_operations.rb --operations PATH --decisions PATH [options]'
    parser.on('--operations PATH', 'Operations JSON using the queue input structure') { |value| options[:operations] = value }
    parser.on('--decisions PATH', 'Routing decisions JSON using the sample output structure') { |value| options[:decisions] = value }
    parser.on('--journal PATH', 'Destination append-only JSONL journal') { |value| options[:journal] = value }
    parser.on('-h', '--help', 'Show this help') do
      puts parser
      exit 0
    end
  end.parse!

  raise OptionParser::MissingArgument, '--operations' unless options[:operations]
  raise OptionParser::MissingArgument, '--decisions' unless options[:decisions]

  operations = RoutingAnalytics::Loader.json_array(options[:operations])
  decisions = RoutingAnalytics::Loader.json_array(options[:decisions])

  operation_ids = operations.map { |operation| operation['operation_id'] }
  decision_ids = decisions.map { |decision| decision['operation_id'] }
  raise RoutingAnalytics::Error, 'duplicate operation_id in operations input' unless operation_ids.uniq.length == operation_ids.length
  raise RoutingAnalytics::Error, 'duplicate operation_id in decisions input' unless decision_ids.uniq.length == decision_ids.length

  missing_decisions = operation_ids - decision_ids
  extra_decisions = decision_ids - operation_ids
  unless missing_decisions.empty? && extra_decisions.empty?
    raise RoutingAnalytics::Error,
      "operation/decision mismatch; missing=#{missing_decisions.join(',')} extra=#{extra_decisions.join(',')}"
  end

  decisions_by_id = decisions.to_h { |decision| [decision['operation_id'], decision] }
  journal = RoutingAnalytics::OperationJournal.new(options[:journal], protected_roots: protected_roots)
  operations.each do |operation|
    journal.append(operation: operation, decision: decisions_by_id.fetch(operation['operation_id']))
  end

  puts "Logged #{operations.length} operations to #{options[:journal]}"
rescue OptionParser::ParseError, RoutingAnalytics::Error, Errno::ENOENT => e
  warn "Operation logging failed: #{e.message}"
  exit 1
end
