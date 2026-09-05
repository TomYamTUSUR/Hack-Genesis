#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'sqlite3'
require 'time'

# One operations_history row is one recorded application to its provider.
# All statuses count. This is not an HTTP request/retry counter: the existing
# history contains only one provider per operation, not a complete request log.
# Window: (at - 60 seconds, at], using SQLite timestamps including UTC offsets.
# By request, in_progress_count/amount now hold ALL applications in that window,
# regardless of status. They are not the total number/value of active operations.
# The first run adds providers.requests_last_minute. Existing programs that
# require the exact original column list (CanonicalDatabaseSource) need adapting.
# Usage: ruby bin/update_provider_minute_stats.rb [--database PATH] [--at ISO8601]
class ProviderMinuteStats
  class Error < StandardError; end

  def initialize(database:, at: nil)
    @path = File.expand_path(database)
    @at = at
  end

  def run
    raise Error, "Database does not exist: #{@path}" unless File.file?(@path)

    database = SQLite3::Database.new(@path, flags: SQLite3::Constants::Open::READWRITE)
    database.busy_timeout = 5000
    database.execute('PRAGMA foreign_keys = ON')
    result = nil
    database.transaction(:immediate) do
      at = (@at || Time.now).getutc
      rows = calculate(database, at: at)
      columns = database.execute('PRAGMA table_info(providers)').map { |row| row['name'] }
      missing = %w[in_progress_count in_progress_amount] - columns
      raise Error, "providers: missing columns #{missing.join(', ')}" unless missing.empty?

      unless columns.include?('requests_last_minute')
        database.execute('ALTER TABLE providers ADD COLUMN requests_last_minute INTEGER NOT NULL DEFAULT 0')
      end
      rows.each do |row|
        database.execute(<<~SQL, row.values_at('requests_last_minute', 'in_progress_count', 'in_progress_amount', 'payment_system_id'))
          UPDATE providers
          SET requests_last_minute = ?, in_progress_count = ?, in_progress_amount = ?
          WHERE payment_system_id = ?
        SQL
      end
      result = {
        'window_start_exclusive' => (at - 60).iso8601(6),
        'window_end_inclusive' => at.iso8601(6),
        'providers' => rows
      }
    end
    result
  ensure
    database&.close
  end

  def calculate(database, at:)
    database.results_as_hash = true
    validate_source!(database)
    # Fail before publishing misleading zeroes for unparseable source dates.
    invalid = database.get_first_value(<<~SQL)
      SELECT operation_id FROM operations_history
      WHERE created_at IS NULL OR julianday(created_at) IS NULL
      LIMIT 1
    SQL
    raise Error, "Invalid or missing operations_history.created_at: #{invalid}" if invalid

    start_at = (at - 60).getutc.iso8601(6)
    end_at = at.getutc.iso8601(6)
    invalid = database.get_first_value(<<~SQL, [start_at, end_at])
      SELECT h.operation_id FROM operations_history h
      LEFT JOIN providers p ON p.payment_system_id = h.payment_system_id
      WHERE julianday(h.created_at) > julianday(?)
        AND julianday(h.created_at) <= julianday(?)
        AND (p.payment_system_id IS NULL OR typeof(h.amount) NOT IN ('integer', 'real') OR h.amount < 0)
      LIMIT 1
    SQL
    raise Error, "Missing provider or invalid amount for operation: #{invalid}" if invalid

    database.execute(<<~SQL, [start_at, end_at])
      SELECT p.payment_system_id, p.payment_system,
             COUNT(h.operation_id) AS requests_last_minute,
             COUNT(DISTINCT h.operation_id) AS in_progress_count,
             COALESCE(SUM(h.amount), 0) AS in_progress_amount
      FROM providers p
      LEFT JOIN operations_history h
        ON h.payment_system_id = p.payment_system_id
       AND julianday(h.created_at) > julianday(?)
       AND julianday(h.created_at) <= julianday(?)
      GROUP BY p.payment_system_id, p.payment_system
      ORDER BY p.payment_system_id
    SQL
  end

  private

  def validate_source!(database)
    {
      'providers' => %w[payment_system_id payment_system],
      'operations_history' => %w[operation_id created_at amount payment_system_id]
    }.each do |table, required|
      columns = database.execute("PRAGMA table_info(#{table})").map { |row| row['name'] }
      missing = required - columns
      raise Error, "#{table}: missing columns #{missing.join(', ')}" unless missing.empty?
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { database: File.expand_path('../DB/operations.db', __dir__) }
  begin
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby bin/update_provider_minute_stats.rb [options]'
      parser.separator 'Updates providers from operations_history for (now - 60 seconds, now], all statuses.'
      parser.separator 'Writes in_progress_count, in_progress_amount; adds requests_last_minute on first run.'
      parser.on('--database PATH', 'Existing SQLite database (default: DB/operations.db)') { |value| options[:database] = value }
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
    warn "Minute statistics update failed: #{e.message}"
    exit 1
  end
end
