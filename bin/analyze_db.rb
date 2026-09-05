#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative '../lib/canonical_database_analytics'

project_root = File.expand_path('..', __dir__)
options = {
  database: File.join(project_root, 'db', 'operations.db'),
  output: File.join(project_root, 'reports', 'routing_report_db.json'),
  stdout: false
}
analytics = nil

begin
  protected_roots = %w[data scripts db].map { |directory| File.join(project_root, directory) }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby bin/analyze_db.rb [options]'
    parser.separator 'Includes coverage, reference checks, cascades, bank/amount segments, UTC day comparison and freshness.'
    parser.separator 'Reads one database snapshot; persisted provider minute statistics are not recalculated.'
    parser.on('--database PATH', 'Canonical SQLite database') { |value| options[:database] = value }
    parser.on('--output PATH', 'Destination JSON report') { |value| options[:output] = value }
    parser.on('--stdout', 'Print JSON without writing a report file') { options[:stdout] = true }
    parser.on('-h', '--help', 'Show this help') do
      puts parser
      exit 0
    end
  end.parse!
  raise OptionParser::InvalidArgument, ARGV.join(' ') unless ARGV.empty?

  unless options[:stdout]
    raise RoutingAnalytics::Error, 'report output must be a file, not a directory' if File.directory?(options[:output])

    if File.expand_path(options[:output]).casecmp?(File.expand_path(options[:database])) ||
       (File.exist?(options[:output]) && File.exist?(options[:database]) &&
        File.identical?(options[:output], options[:database]))
      raise RoutingAnalytics::Error, 'report output must not overwrite the source database'
    end
  end

  analytics = RoutingAnalytics::CanonicalDatabaseAnalytics.new(options[:database])
  report = analytics.report
  if options[:stdout]
    puts JSON.pretty_generate(report)
  else
    RoutingAnalytics::ReportWriter.write(options[:output], report, protected_roots: protected_roots)
    puts "Analytics report written to #{options[:output]}"
  end
rescue OptionParser::ParseError, RoutingAnalytics::Error, SQLite3::Exception, SystemCallError => e
  warn "Analytics failed: #{e.message}"
  exit 1
ensure
  analytics&.close
end
