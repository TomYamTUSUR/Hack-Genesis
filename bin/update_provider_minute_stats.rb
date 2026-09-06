#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative '../lib/provider_minute_stats'

options = { database: File.expand_path('../db/operations.db', __dir__) }
begin
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby bin/update_provider_minute_stats.rb [options]'
    parser.separator 'Recalculates providers from all operations_history through now (or --at), all statuses.'
    parser.separator 'Shares, status rates and avg_latency_sec use the analysis window; missing metric columns are added.'
    parser.separator 'conversion_24h keeps its 24-hour window; requests_last_minute keeps its 60-second window if present.'
    parser.separator 'Does not update in_progress_count/in_progress_amount, daily totals, targets or limits.'
    parser.on('--database PATH', 'Existing SQLite database (default: db/operations.db)') { |value| options[:database] = value }
    parser.on('--window-seconds N|all', 'Analysis window: positive integer seconds or all (default: all history)') do |value|
      unless value == 'all' || (value.match?(/\A[0-9]+\z/) && value.to_i.positive?)
        raise OptionParser::InvalidArgument, '--window-seconds must be a positive integer or all'
      end

      options[:window_seconds] = value == 'all' ? nil : value.to_i
    end
    parser.on('--dry-run', 'Read-only JSON report; do not update provider fields') { options[:dry_run] = true }
    parser.on('--at ISO8601', 'Window end with timezone, e.g. 2026-07-29T08:01:00+03:00 (default: now)') do |value|
      raise OptionParser::InvalidArgument, '--at must include Z or a UTC offset' unless value.match?(/(?:Z|[+-]\d{2}:?\d{2})\z/)

      options[:at] = Time.iso8601(value)
    end
    parser.on('-h', '--help', 'Show help') { puts parser; exit }
  end.parse!
  raise OptionParser::InvalidArgument, ARGV.join(' ') unless ARGV.empty?

  puts JSON.pretty_generate(ProviderMinuteStats.new(**options).run)
rescue ProviderMinuteStats::Error, SQLite3::Exception, OptionParser::ParseError,
       SystemCallError, ArgumentError => e
  warn "Provider statistics update failed: #{e.message}"
  exit 1
end
