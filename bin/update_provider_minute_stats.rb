#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'sqlite3'
require 'time'
require_relative '../lib/provider_minute_metrics'

# One operations_history row is one recorded application to its provider.
# All statuses count. This is not an HTTP request/retry counter: the existing
# history contains only one provider per operation, not a complete request log.
# Window: (at - 60 seconds, at], using SQLite timestamps including UTC offsets.
# By request, in_progress_count/amount now hold ALL applications in that window,
# regardless of status. They are not the total number/value of active operations.
# Never changes the schema. Writes requests_last_minute only if it already exists.
# Also updates conversion_24h (ratio over all statuses) and avg_latency_sec (minute,
# all known latencies, rounded to seconds). Missing observations produce NULL.
# Daily created-operation totals are report-only; there is no completion time to
# safely recalculate daily_approved_amount. Targets and limits are never updated.
# Usage: ruby bin/update_provider_minute_stats.rb [--database PATH] [--at ISO8601] [--dry-run]
class ProviderMinuteStats
  class Error < StandardError; end

  def initialize(database:, at: nil, dry_run: false)
    @path = File.expand_path(database)
    @at = at
    @dry_run = dry_run
  end

  def run
    raise Error, "Database does not exist: #{@path}" unless File.file?(@path)

    flags = @dry_run ? SQLite3::Constants::Open::READONLY : SQLite3::Constants::Open::READWRITE
    database = SQLite3::Database.new(@path, flags: flags)
    database.busy_timeout = 5000
    database.execute('PRAGMA foreign_keys = ON')
    result = nil
    database.transaction(@dry_run ? :deferred : :immediate) do
      at = (@at || Time.now).getutc
      result = build_report(database, at: at)
      columns = database.execute('PRAGMA table_info(providers)').map { |row| row['name'] }
      fields = %w[in_progress_count in_progress_amount conversion_24h avg_latency_sec]
      missing = fields - columns
      raise Error, "providers: missing columns #{missing.join(', ')}" unless missing.empty?

      fields << 'requests_last_minute' if columns.include?('requests_last_minute')
      unless @dry_run
        result.fetch('providers').each do |row|
          assignments = fields.map { |field| "#{field} = ?" }.join(', ')
          database.execute("UPDATE providers SET #{assignments} WHERE payment_system_id = ?",
                           row.values_at(*fields, 'payment_system_id'))
        end
      end
      result['persistence'] = { 'dry_run' => @dry_run, 'columns' => fields, 'schema_changed' => false }
    end
    result
  ensure
    database&.close
  end

  def calculate(database, at:)
    build_report(database, at: at).fetch('providers')
  end

  def build_report(database, at:)
    database.results_as_hash = true
    validate_source!(database)
    # Fail before publishing misleading zeroes for unparseable source dates.
    invalid = database.get_first_value(<<~SQL)
      SELECT operation_id FROM operations_history
      WHERE created_at IS NULL OR julianday(created_at) IS NULL
      LIMIT 1
    SQL
    raise Error, "Invalid or missing operations_history.created_at: #{invalid}" if invalid

    start_at = (at - 86_400).getutc.iso8601(6)
    end_at = at.getutc.iso8601(6)
    invalid = database.get_first_value(<<~SQL, [start_at, end_at])
      SELECT h.operation_id FROM operations_history h
      LEFT JOIN providers p ON p.payment_system_id = h.payment_system_id
      WHERE julianday(h.created_at) >= julianday(?)
        AND julianday(h.created_at) <= julianday(?)
        AND (p.payment_system_id IS NULL OR typeof(h.amount) NOT IN ('integer', 'real') OR h.amount < 0
             OR (h.latency_sec IS NOT NULL AND (typeof(h.latency_sec) NOT IN ('integer', 'real') OR h.latency_sec < 0)))
      LIMIT 1
    SQL
    raise Error, "Missing provider or invalid amount/latency for operation: #{invalid}" if invalid

    history = database.execute(<<~SQL, [start_at, end_at])
      SELECT operation_id, payment_system_id, amount, status, bank, latency_sec,
             julianday(created_at) AS created_jd
      FROM operations_history
      WHERE julianday(created_at) >= julianday(?) AND julianday(created_at) <= julianday(?)
      ORDER BY julianday(created_at), operation_id
    SQL
    providers = database.execute('SELECT * FROM providers ORDER BY payment_system_id')
    windows = period_windows(at.getutc)
    cohorts = windows.to_h do |name, window|
      lower = database.get_first_value('SELECT julianday(?)', [window['start']])
      upper = database.get_first_value('SELECT julianday(?)', [window['end']])
      selected = history.select do |row|
        after_start = window['start_inclusive'] ? row['created_jd'] >= lower : row['created_jd'] > lower
        after_start && row['created_jd'] <= upper
      end
      [name, selected]
    end
    totals = cohorts.transform_values { |rows| ProviderMinuteMetrics.summary(rows) }
    groups = cohorts.transform_values { |rows| rows.group_by { |row| row['payment_system_id'] } }
    rows = providers.map do |provider|
      id = provider.fetch('payment_system_id')
      metrics = groups.to_h do |name, grouped|
        [name, ProviderMinuteMetrics.shares(ProviderMinuteMetrics.summary(grouped.fetch(id, [])), totals.fetch(name))]
      end
      minute = metrics.fetch('minute')
      previous = metrics.fetch('previous_minute')
      day = metrics.fetch('last_24h')
      conversion = day['count'].zero? ? nil : day.dig('statuses', 'approved', 'count').to_f / day['count']
      {
        'payment_system_id' => id, 'payment_system' => provider.fetch('payment_system'),
        'requests_last_minute' => minute['count'], 'in_progress_count' => minute['count'],
        'in_progress_amount' => minute['amount'], 'conversion_24h' => conversion,
        'avg_latency_sec' => minute.dig('latency', 'avg_sec')&.round,
        'periods' => metrics,
        'minute_change' => {
          'count_delta' => minute['count'] - previous['count'],
          'amount_delta' => minute['amount'] - previous['amount'],
          'count_change_pct' => ProviderMinuteMetrics.change(minute['count'], previous['count']),
          'amount_change_pct' => ProviderMinuteMetrics.change(minute['amount'], previous['amount'])
        },
        'targets' => ProviderMinuteMetrics.targets(provider, minute),
        'minute_breakdown' => ProviderMinuteMetrics.breakdown(groups.fetch('minute').fetch(id, []), minute)
      }
    end
    {
      'window_start_exclusive' => (at - 60).getutc.iso8601(6),
      'window_end_inclusive' => end_at,
      'windows' => windows, 'totals' => totals, 'providers' => rows,
      'definitions' => {
        'source' => 'operations_history.created_at; one recorded application per operation, all statuses',
        'daily' => 'UTC calendar day; approved operations created today, not payments completed today',
        'conversion_24h' => 'approved / all operations created in the last 24 hours; ratio 0..1',
        'avg_latency_sec' => 'all non-null latencies in the last minute, rounded to integer seconds',
        'terminal_statuses' => ProviderMinuteMetrics::TERMINAL_STATUSES,
        'p95' => 'nearest rank: sorted[ceil(0.95 * count) - 1]',
        'breakdown_shares' => 'within this provider in the last minute',
        'empty_denominator' => 'null; counts and amounts for empty cohorts are zero',
        'snapshot_limits' => 'provider snapshot freshness is unknown; no timestamp is stored',
        'in_progress' => 'minute counts and amounts by request; not concurrent in-progress workload',
        'historical_at' => 'uses currently stored statuses, not a reconstruction of past status changes'
      }
    }
  end

  private

  def period_windows(at)
    {
      'minute' => [at - 60, at, false],
      'previous_minute' => [at - 120, at - 60, false],
      'last_hour' => [at - 3600, at, false],
      'last_24h' => [at - 86_400, at, false],
      'today_created_operations' => [Time.utc(at.year, at.month, at.day), at, true]
    }.transform_values do |start_at, end_at, inclusive|
      { 'start' => start_at.iso8601(6), 'end' => end_at.iso8601(6), 'start_inclusive' => inclusive, 'end_inclusive' => true }
    end
  end

  def validate_source!(database)
    {
      'providers' => %w[payment_system_id payment_system],
      'operations_history' => %w[operation_id created_at amount payment_system_id status latency_sec bank]
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
      parser.separator 'Writes existing in_progress_count, in_progress_amount, conversion_24h and avg_latency_sec.'
      parser.separator 'Writes requests_last_minute only if present. Never changes the schema. Other metrics are JSON-only.'
      parser.on('--database PATH', 'Existing SQLite database (default: DB/operations.db)') { |value| options[:database] = value }
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
    warn "Minute statistics update failed: #{e.message}"
    exit 1
  end
end
