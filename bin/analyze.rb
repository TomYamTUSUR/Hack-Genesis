#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative '../lib/routing_analytics'

project_root = File.expand_path('..', __dir__)
options = {
  database: File.join(project_root, 'DB', 'operations.db'),
  output: File.join(project_root, 'reports', 'routing_report.json'),
  stdout: false
}
source = nil

begin
  protected_roots = [File.join(project_root, 'data'), File.join(project_root, 'scripts')]
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby bin/analyze.rb [options]'
    parser.on('--database PATH', 'SQLite database using the project schema') { |value| options[:database] = value }
    parser.on('--output PATH', 'Destination JSON report') { |value| options[:output] = value }
    parser.on('--stdout', 'Print the report instead of writing it') { options[:stdout] = true }
    parser.on('-h', '--help', 'Show this help') do
      puts parser
      exit 0
    end
  end.parse!

  source = RoutingAnalytics::DatabaseSource.new(options[:database])
  report = RoutingAnalytics::Analyzer.new(**source.analysis_inputs).report

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
  source&.close
end
