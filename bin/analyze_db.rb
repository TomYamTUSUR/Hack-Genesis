#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative '../lib/canonical_database_analytics'

project_root = File.expand_path('..', __dir__)
options = {
  database: File.join(project_root, 'DB', 'operations.db'),
  output: File.join(project_root, 'reports', 'routing_report_db.json'),
  stdout: false
}
analytics = nil

begin
  protected_roots = %w[data scripts DB].map { |directory| File.join(project_root, directory) }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby bin/analyze_db.rb [options]'
    parser.on('--database PATH', 'Canonical SQLite database') { |value| options[:database] = value }
    parser.on('--output PATH', 'Destination JSON report') { |value| options[:output] = value }
    parser.on('--stdout', 'Print JSON without writing a report file') { options[:stdout] = true }
    parser.on('-h', '--help', 'Show this help') do
      puts parser
      exit 0
    end
  end.parse!

  analytics = RoutingAnalytics::CanonicalDatabaseAnalytics.new(options[:database])
  report = analytics.report
  if options[:stdout]
    puts JSON.pretty_generate(report)
  else
    RoutingAnalytics::ReportWriter.write(options[:output], report, protected_roots: protected_roots)
    puts "Analytics report written to #{options[:output]}"
  end
rescue OptionParser::ParseError, RoutingAnalytics::Error, Errno::ENOENT => e
  warn "Analytics failed: #{e.message}"
  exit 1
ensure
  analytics&.close
end
