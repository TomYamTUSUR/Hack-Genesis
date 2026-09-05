# frozen_string_literal: true

require 'csv'
require 'date'
require 'fileutils'
require 'json'
require 'sqlite3'
require 'time'

module RoutingAnalytics
  class Error < StandardError; end

  module PathGuard
    module_function

    def ensure_writable!(path, protected_roots)
      normalized_path = normalize(path)
      protected = protected_roots.any? do |root|
        normalized_root = normalize(root)
        normalized_path == normalized_root || normalized_path.start_with?("#{normalized_root}/")
      end
      raise Error, "refusing to write inside protected source directory: #{path}" if protected

      path
    end

    def normalize(path)
      File.expand_path(path).tr('\\', '/').downcase.sub(%r{/+$}, '')
    end
    private_class_method :normalize
  end

  module Utils
    module_function

    def number(value)
      return nil if value.nil? || value == ''

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def clean_number(value, digits = 2)
      return nil if value.nil?

      rounded = value.round(digits)
      rounded == rounded.to_i ? rounded.to_i : rounded
    end

    def percentage(numerator, denominator)
      return nil if denominator.to_f.zero?

      clean_number(100.0 * numerator.to_f / denominator.to_f)
    end

    def parse_time(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def percentile(values, fraction)
      sorted = values.compact.map(&:to_f).sort
      return nil if sorted.empty?

      index = [(sorted.length * fraction).ceil - 1, 0].max
      clean_number(sorted[index])
    end

    def median(values)
      sorted = values.compact.map(&:to_f).sort
      return nil if sorted.empty?

      middle = sorted.length / 2
      value = if sorted.length.odd?
                sorted[middle]
              else
                (sorted[middle - 1] + sorted[middle]) / 2.0
              end
      clean_number(value)
    end
  end

  class Loader
    HISTORY_COLUMNS = %w[
      operation_id created_at amount bank card_brand payment_system status latency_sec
    ].freeze

    class << self
      def providers(path)
        data = parse_json(path)
        unless data.is_a?(Hash) && data['providers'].is_a?(Array)
          raise Error, "#{path}: expected an object with a providers array"
        end

        data
      end

      def history(path)
        table = CSV.read(path, headers: true, encoding: 'bom|utf-8')
        missing_columns = HISTORY_COLUMNS - table.headers
        unless missing_columns.empty?
          raise Error, "#{path}: missing history columns: #{missing_columns.join(', ')}"
        end

        table.map(&:to_h)
      rescue CSV::MalformedCSVError => e
        raise Error, "#{path}: malformed CSV: #{e.message}"
      end

      def json_array(path)
        data = json_value(path)
        data.is_a?(Array) ? data : [data]
      end

      def json_value(path)
        parse_json(path)
      end

      private

      def parse_json(path)
        JSON.parse(File.read(path, encoding: 'UTF-8'))
      rescue JSON::ParserError => e
        raise Error, "#{path}: malformed JSON: #{e.message}"
      end
    end
  end

  class DatabaseBase
    REQUIRED_TABLES = %w[
      analytics_metadata eligible_providers operations_history operations_queue provider_skip_reasons
      providers reference_decisions routing_attempts routing_decisions
    ].freeze

    attr_reader :path

    def close
      @database&.close
    end

    private

    def validate_schema!
      existing = rows("SELECT name FROM sqlite_master WHERE type = 'table'").map { |row| row['name'] }
      missing = REQUIRED_TABLES - existing
      raise Error, "#{path}: missing database tables: #{missing.join(', ')}" unless missing.empty?
    end

    def rows(sql, bindings = [])
      @database.execute(sql, bindings).map { |row| string_key_hash(row) }
    end

    def first_value(sql, bindings = [])
      @database.get_first_value(sql, bindings)
    end

    def string_key_hash(row)
      row.each_with_object({}) do |(key, value), result|
        result[key] = value if key.is_a?(String)
      end
    end
  end

  # Read-only adapter from the normalized SQLite schema to Analyzer inputs.
  class DatabaseSource < DatabaseBase
    def initialize(path)
      @path = File.expand_path(path)
      raise Error, "database does not exist: #{@path}" unless File.file?(@path)

      @database = SQLite3::Database.new(
        @path,
        flags: SQLite3::Constants::Open::READONLY
      )
      @database.results_as_hash = true
      @database.execute('PRAGMA query_only = ON')
      validate_schema!
    rescue SQLite3::Exception => e
      close
      raise Error, "unable to read database #{@path}: #{e.message}"
    end

    def analysis_inputs
      {
        provider_data: provider_data,
        history_rows: history_rows,
        routing_events: routing_events,
        pending_operations: pending_operations,
        source_metadata: source_metadata
      }
    end

    private

    def provider_data
      metadata = rows('SELECT meta_key, meta_value FROM analytics_metadata')
        .to_h { |row| [row['meta_key'], row['meta_value']] }
      providers = rows('SELECT * FROM providers ORDER BY priority, payment_system_id').map do |provider|
        provider['banks'] = parse_banks(provider['banks'])
        provider['exclude_banks'] = provider['exclude_banks'].to_i == 1
        provider['allow_negative_agreement'] = provider['allow_negative_agreement'].to_i == 1
        provider
      end

      {
        'snapshot_at' => metadata['snapshot_at'],
        'gateway' => metadata['gateway'],
        'merchant' => metadata['merchant'],
        'providers' => providers
      }
    end

    def history_rows
      rows(<<~SQL)
        SELECT h.operation_id, h.created_at, h.amount, h.bank, h.card_brand,
               p.payment_system, h.status, h.latency_sec
        FROM operations_history h
        LEFT JOIN providers p ON p.payment_system_id = h.payment_system_id
        ORDER BY h.created_at, h.operation_id
      SQL
    end

    def pending_operations
      rows(<<~SQL)
        SELECT operation_id, created_at, amount, bank, card_brand
        FROM operations_queue
        ORDER BY created_at, operation_id
      SQL
    end

    def routing_events
      attempts = rows(<<~SQL).group_by { |row| row['operation_id'] }
        SELECT a.operation_id, p.payment_system AS provider, a.decision, a.reason,
               a.attempt_number
        FROM routing_attempts a
        LEFT JOIN providers p ON p.payment_system_id = a.payment_system_id
        ORDER BY a.operation_id, a.attempt_number
      SQL

      rows(<<~SQL).map do |row|
        SELECT d.operation_id, d.created_at AS decision_created_at,
               d.simulated_result, d.latency_sec,
               selected.payment_system AS selected_provider,
               COALESCE(h.created_at, q.created_at, d.created_at) AS operation_created_at,
               COALESCE(h.amount, q.amount) AS amount,
               COALESCE(h.bank, q.bank) AS bank,
               COALESCE(h.card_brand, q.card_brand) AS card_brand
        FROM routing_decisions d
        LEFT JOIN providers selected
          ON selected.payment_system_id = d.selected_payment_system_id
        LEFT JOIN operations_history h ON h.operation_id = d.operation_id
        LEFT JOIN operations_queue q ON q.operation_id = d.operation_id
        ORDER BY d.created_at, d.operation_id
      SQL
        {
          'logged_at' => row['decision_created_at'],
          'event' => 'routing_operation',
          'operation_id' => row['operation_id'],
          'operation' => {
            'operation_id' => row['operation_id'],
            'created_at' => row['operation_created_at'],
            'amount' => row['amount'],
            'bank' => row['bank'],
            'card_brand' => row['card_brand']
          },
          'routing_decision' => {
            'operation_id' => row['operation_id'],
            'selected_provider' => row['selected_provider'],
            'attempts' => (attempts[row['operation_id']] || []).map do |attempt|
              {
                'provider' => attempt['provider'],
                'decision' => attempt['decision'],
                'reason' => attempt['reason']
              }
            end,
            'simulated_result' => row['simulated_result'],
            'latency_sec' => row['latency_sec']
          }
        }
      end
    end

    def source_metadata
      table_rows = REQUIRED_TABLES.to_h do |table|
        [table, first_value("SELECT COUNT(*) FROM #{table}")]
      end
      foreign_key_count = REQUIRED_TABLES.sum do |table|
        rows("PRAGMA foreign_key_list(#{table})").length
      end
      orphans = {
        'history_unknown_provider' => first_value(<<~SQL),
          SELECT COUNT(*) FROM operations_history h
          LEFT JOIN providers p ON p.payment_system_id = h.payment_system_id
          WHERE p.payment_system_id IS NULL
        SQL
        'decision_unknown_provider' => first_value(<<~SQL),
          SELECT COUNT(*) FROM routing_decisions d
          LEFT JOIN providers p ON p.payment_system_id = d.selected_payment_system_id
          WHERE d.selected_payment_system_id IS NOT NULL AND p.payment_system_id IS NULL
        SQL
        'decision_without_operation' => first_value(<<~SQL),
          SELECT COUNT(*) FROM routing_decisions d
          LEFT JOIN operations_history h ON h.operation_id = d.operation_id
          LEFT JOIN operations_queue q ON q.operation_id = d.operation_id
          WHERE h.operation_id IS NULL AND q.operation_id IS NULL
        SQL
        'attempt_unknown_provider' => first_value(<<~SQL),
          SELECT COUNT(*) FROM routing_attempts a
          LEFT JOIN providers p ON p.payment_system_id = a.payment_system_id
          WHERE p.payment_system_id IS NULL
        SQL
        'attempt_without_decision' => first_value(<<~SQL)
          SELECT COUNT(*) FROM routing_attempts a
          LEFT JOIN routing_decisions d ON d.operation_id = a.operation_id
          WHERE d.operation_id IS NULL
        SQL
      }

      {
        'type' => 'sqlite',
        'database' => path,
        'integrity_check' => first_value('PRAGMA integrity_check'),
        'foreign_key_definitions' => foreign_key_count,
        'table_rows' => table_rows,
        'orphans' => orphans
      }
    end

    def parse_banks(value)
      return [] if value.nil? || value.to_s.strip.empty?

      parsed = JSON.parse(value)
      return parsed if parsed.is_a?(Array)

      value.to_s.split(',').map(&:strip).reject(&:empty?)
    rescue JSON::ParserError
      value.to_s.split(',').map(&:strip).reject(&:empty?)
    end
  end

  class DatabaseWriter < DatabaseBase
    PROVIDER_COLUMNS = %w[
      payment_system status traffic_percentage priority limit_amount_min limit_amount_max
      daily_amount_limit daily_approved_amount in_progress_count_limit in_progress_count
      in_progress_amount_limit in_progress_amount available_requisites conversion_24h
      avg_latency_sec banks exclude_banks provider_margin_pct merchant_margin_pct
      allow_negative_agreement note volume_share_pct requests_per_minute_limit
      daily_turnover_min daily_turnover_max
    ].freeze

    def initialize(path, protected_roots: [])
      @path = File.expand_path(path)
      PathGuard.ensure_writable!(@path, protected_roots)
      raise Error, "database does not exist: #{@path}" unless File.file?(@path)

      @database = SQLite3::Database.new(@path)
      @database.results_as_hash = true
      @database.busy_timeout = 5_000
      @database.execute('PRAGMA foreign_keys = ON')
      validate_schema!
    rescue SQLite3::Exception => e
      close
      raise Error, "unable to open database #{@path}: #{e.message}"
    end

    def import_sources(provider_data:, history_rows:, queue_operations:, reference_data: {})
      counts = { metadata: 0, providers: 0, history: 0, queue: 0, references: 0 }
      @database.transaction do
        %w[snapshot_at gateway merchant].each do |key|
          next if provider_data[key].nil?

          upsert('analytics_metadata', {
            'meta_key' => key,
            'meta_value' => provider_data[key]
          }, %w[meta_key])
          counts[:metadata] += 1
        end

        Array(provider_data['providers']).each do |provider|
          values = PROVIDER_COLUMNS.to_h do |column|
            value = provider[column]
            value = JSON.generate(value || []) if column == 'banks'
            value = value ? 1 : 0 if %w[exclude_banks allow_negative_agreement].include?(column)
            [column, value]
          end
          upsert('providers', values, %w[payment_system])
          counts[:providers] += 1
        end

        history_rows.each do |row|
          provider_id = provider_id!(row['payment_system'])
          upsert('operations_history', {
            'operation_id' => required!(row, 'operation_id'),
            'created_at' => required!(row, 'created_at'),
            'amount' => required!(row, 'amount'),
            'bank' => required!(row, 'bank'),
            'card_brand' => row['card_brand'],
            'payment_system_id' => provider_id,
            'status' => required!(row, 'status'),
            'latency_sec' => row['latency_sec']
          }, %w[operation_id])
          @database.execute('DELETE FROM operations_queue WHERE operation_id = ?', row['operation_id'])
          counts[:history] += 1
        end

        queue_operations.each do |operation|
          operation_id = required!(operation, 'operation_id')
          next if processed_operation?(operation_id)

          upsert('operations_queue', {
            'operation_id' => operation_id,
            'created_at' => required!(operation, 'created_at'),
            'amount' => required!(operation, 'amount'),
            'bank' => required!(operation, 'bank'),
            'card_brand' => operation['card_brand'],
            'payout_requisite_sbp_phone' => operation.dig('payout_requisite', 'sbp', 'phone'),
            'payout_requisite_bank_name' => operation.dig('payout_requisite', 'sbp', 'bank_name')
          }, %w[operation_id])
          counts[:queue] += 1
        end

        Array(reference_data['deterministic_cases']).each do |reference|
          provider_id = provider_id!(reference['required_provider'])
          upsert('reference_decisions', {
            'operation_id' => required!(reference, 'operation_id'),
            'required_payment_system_id' => provider_id,
            'reason' => reference['reason']
          }, %w[operation_id])
          counts[:references] += 1
        end
      end
      counts
    rescue SQLite3::Exception => e
      raise Error, "database import failed: #{e.message}"
    end

    def log_operations(operations:, decisions:, logged_at: Time.now)
      validate_pairs!(operations, decisions)
      decisions_by_id = decisions.to_h { |decision| [decision['operation_id'], decision] }

      @database.transaction do
        operations.each do |operation|
          decision = decisions_by_id.fetch(operation['operation_id'])
          operation_id = required!(operation, 'operation_id')
          provider_id = provider_id!(decision['selected_provider'])
          created_at = operation['created_at'] || logged_at.iso8601
          status = decision['simulated_result'] || 'unknown'

          upsert('operations_history', {
            'operation_id' => operation_id,
            'created_at' => created_at,
            'amount' => required!(operation, 'amount'),
            'bank' => required!(operation, 'bank'),
            'card_brand' => operation['card_brand'],
            'payment_system_id' => provider_id,
            'status' => status,
            'latency_sec' => decision['latency_sec']
          }, %w[operation_id])
          upsert('routing_decisions', {
            'operation_id' => operation_id,
            'selected_payment_system_id' => provider_id,
            'simulated_result' => status,
            'latency_sec' => decision['latency_sec'],
            'created_at' => logged_at.iso8601
          }, %w[operation_id])

          %w[routing_attempts eligible_providers provider_skip_reasons].each do |table|
            @database.execute("DELETE FROM #{table} WHERE operation_id = ?", operation_id)
          end
          decision['attempts'].each_with_index do |attempt, index|
            attempt_provider_id = provider_id!(attempt['provider'])
            attempt_number = index + 1
            @database.execute(<<~SQL, [operation_id, attempt_provider_id, attempt_number, attempt['decision'], attempt['reason'], logged_at.iso8601])
              INSERT INTO routing_attempts
                (operation_id, payment_system_id, attempt_number, decision, reason, created_at)
              VALUES (?, ?, ?, ?, ?, ?)
            SQL
            @database.execute(<<~SQL, [operation_id, attempt_provider_id, attempt['decision'] == 'skipped' ? 0 : 1, logged_at.iso8601])
              INSERT INTO eligible_providers
                (operation_id, payment_system_id, is_eligible, checked_at)
              VALUES (?, ?, ?, ?)
            SQL
            next unless attempt['decision'] == 'skipped'

            @database.execute(<<~SQL, [operation_id, attempt_provider_id, attempt['reason'] || 'unknown', logged_at.iso8601])
              INSERT INTO provider_skip_reasons
                (operation_id, payment_system_id, reason, created_at)
              VALUES (?, ?, ?, ?)
            SQL
          end
          @database.execute('DELETE FROM operations_queue WHERE operation_id = ?', operation_id)
        end
      end
      operations.length
    rescue SQLite3::Exception => e
      raise Error, "operation logging failed: #{e.message}"
    end

    private

    def validate_pairs!(operations, decisions)
      operation_ids = operations.map { |operation| operation['operation_id'] }
      decision_ids = decisions.map { |decision| decision['operation_id'] }
      raise Error, 'duplicate operation_id in operations input' unless operation_ids.uniq.length == operation_ids.length
      raise Error, 'duplicate operation_id in decisions input' unless decision_ids.uniq.length == decision_ids.length

      missing = operation_ids - decision_ids
      extra = decision_ids - operation_ids
      unless missing.empty? && extra.empty?
        raise Error, "operation/decision mismatch; missing=#{missing.join(',')} extra=#{extra.join(',')}"
      end

      decisions.each do |decision|
        raise Error, 'routing decision must contain selected_provider' unless decision['selected_provider']
        raise Error, 'routing decision attempts must be an array' unless decision['attempts'].is_a?(Array)
      end
    end

    def provider_id!(payment_system)
      id = first_value('SELECT payment_system_id FROM providers WHERE payment_system = ?', [payment_system])
      raise Error, "unknown provider: #{payment_system.inspect}" unless id

      id
    end

    def processed_operation?(operation_id)
      first_value(<<~SQL, [operation_id, operation_id]).to_i.positive?
        SELECT EXISTS(
          SELECT 1 FROM operations_history WHERE operation_id = ?
          UNION ALL
          SELECT 1 FROM routing_decisions WHERE operation_id = ?
        )
      SQL
    end

    def required!(object, key)
      value = object[key]
      raise Error, "missing required field: #{key}" if value.nil? || value.to_s.empty?

      value
    end

    def upsert(table, values, conflict_columns)
      columns = values.keys
      updates = columns.reject { |column| conflict_columns.include?(column) }
      sql = <<~SQL
        INSERT INTO #{table} (#{columns.join(', ')})
        VALUES (#{(['?'] * columns.length).join(', ')})
        ON CONFLICT (#{conflict_columns.join(', ')}) DO UPDATE SET
          #{updates.map { |column| "#{column} = excluded.#{column}" }.join(', ')}
      SQL
      @database.execute(sql, values.values)
    end
  end

  class Analyzer
    BASE_STATUSES = %w[approved rejected expired].freeze

    def initialize(provider_data:, history_rows:, routing_events: [], pending_operations: [], source_metadata: {})
      @provider_data = provider_data
      @providers = provider_data.fetch('providers')
      @history_rows = history_rows
      @routing_events = routing_events
      @pending_operations = pending_operations
      @source_metadata = source_metadata
      @provider_by_name = @providers.to_h { |provider| [provider['payment_system'], provider] }
    end

    def report(generated_at: Time.now)
      latest_events = latest_routing_events
      records = combined_records(latest_events)
      pending = unprocessed_pending_operations(latest_events)
      distribution = distribution_for(records)
      utilization = utilization_for_providers
      recommendation_records = latest_day_records(records)
      recommendation_distribution = distribution_for(recommendation_records)

      {
        'period' => period_label(records),
        'window' => period_window(records),
        'generated_at' => generated_at.iso8601,
        'source' => @source_metadata,
        'provider_snapshot_at' => @provider_data['snapshot_at'],
        'gateway' => @provider_data['gateway'],
        'merchant' => @provider_data['merchant'],
        'total_operations' => records.length,
        'pending_operations' => pending.length,
        'all_operations_seen' => records.length + pending.length,
        'total_amount' => Utils.clean_number(records.sum { |record| record['amount'].to_f }),
        'pending_queue' => pending_queue_summary(pending),
        'distribution' => distribution,
        'daily_distribution' => daily_distribution(records),
        'status_summary' => status_summary(records),
        'latency' => latency_summary(records),
        'skip_reasons' => skip_reasons(latest_events),
        'projected_daily_utilization' => utilization,
        'provider_state' => provider_state,
        'data_quality' => data_quality(records, latest_events),
        'recommendation_period' => period_label(recommendation_records),
        'recommendations' => recommendations(recommendation_distribution, utilization)
      }
    end

    private

    def normalized_history
      @history_rows.map do |row|
        {
          'operation_id' => row['operation_id'],
          'created_at' => row['created_at'],
          'amount' => Utils.number(row['amount']),
          'bank' => row['bank'],
          'card_brand' => row['card_brand'],
          'payment_system' => row['payment_system'],
          'status' => row['status'],
          'latency_sec' => Utils.number(row['latency_sec']),
          'source' => 'operations_history'
        }
      end
    end

    def normalized_event(event)
      operation = event.fetch('operation', {})
      decision = event.fetch('routing_decision', {})
      {
        'operation_id' => operation['operation_id'] || event['operation_id'],
        'created_at' => operation['created_at'] || event['logged_at'],
        'amount' => Utils.number(operation['amount']),
        'bank' => operation['bank'],
        'card_brand' => operation['card_brand'],
        'payment_system' => decision['selected_provider'],
        'status' => decision['simulated_result'] || 'unknown',
        'latency_sec' => Utils.number(decision['latency_sec']),
        'source' => 'routing_decisions'
      }
    end

    def latest_routing_events
      latest = {}
      @routing_events.each do |event|
        operation_id = event['operation_id'] || event.dig('operation', 'operation_id')
        next if operation_id.nil? || operation_id.to_s.empty?

        latest[operation_id] = event
      end
      latest.values
    end

    def combined_records(latest_events)
      by_operation = {}
      normalized_history.each { |record| by_operation[record['operation_id']] = record }
      latest_events.each do |event|
        record = normalized_event(event)
        by_operation[record['operation_id']] = record
      end

      by_operation.values.sort_by do |record|
        [Utils.parse_time(record['created_at']) || Time.at(0), record['operation_id'].to_s]
      end
    end

    def unprocessed_pending_operations(latest_events)
      processed_ids = @history_rows.filter_map { |row| row['operation_id'] }
      processed_ids += latest_events.filter_map do |event|
        event['operation_id'] || event.dig('operation', 'operation_id')
      end
      @pending_operations.reject { |operation| processed_ids.include?(operation['operation_id']) }
    end

    def pending_queue_summary(operations)
      amounts = operations.filter_map { |operation| Utils.number(operation['amount']) }
      times = operations.filter_map { |operation| Utils.parse_time(operation['created_at']) }
      banks = operations.each_with_object(Hash.new(0)) do |operation, result|
        result[operation['bank'] || 'unknown'] += 1
      end

      {
        'count' => operations.length,
        'total_amount' => Utils.clean_number(amounts.sum),
        'min_amount' => amounts.empty? ? nil : Utils.clean_number(amounts.min),
        'max_amount' => amounts.empty? ? nil : Utils.clean_number(amounts.max),
        'from' => times.empty? ? nil : times.min.iso8601,
        'to' => times.empty? ? nil : times.max.iso8601,
        'banks' => banks.sort.to_h
      }
    end

    def daily_distribution(records)
      records.group_by { |record| Utils.parse_time(record['created_at'])&.strftime('%Y-%m-%d') || 'unknown' }
        .sort.to_h.transform_values do |day_records|
          total_amount = day_records.sum { |record| record['amount'].to_f }
          by_provider = day_records.group_by { |record| record['payment_system'] || 'unknown' }
            .sort.to_h.transform_values do |provider_records|
              amount = provider_records.sum { |record| record['amount'].to_f }
              {
                'count' => provider_records.length,
                'share_pct' => Utils.percentage(provider_records.length, day_records.length),
                'amount' => Utils.clean_number(amount),
                'volume_share_pct' => Utils.percentage(amount, total_amount)
              }
            end
          {
            'total_operations' => day_records.length,
            'total_amount' => Utils.clean_number(total_amount),
            'providers' => by_provider
          }
        end
    end

    def latest_day_records(records)
      dated_records = records.filter_map do |record|
        time = Utils.parse_time(record['created_at'])
        time && [time.strftime('%Y-%m-%d'), record]
      end
      return [] if dated_records.empty?

      latest_date = dated_records.map(&:first).max
      dated_records.select { |date, _record| date == latest_date }.map(&:last)
    end

    def distribution_for(records)
      names = (@providers.map { |provider| provider['payment_system'] } +
        records.map { |record| record['payment_system'] }).compact.uniq
      total_amount = records.sum { |record| record['amount'].to_f }

      names.to_h do |name|
        provider = @provider_by_name[name] || {}
        provider_records = records.select { |record| record['payment_system'] == name }
        count = provider_records.length
        amount = provider_records.sum { |record| record['amount'].to_f }
        statuses = provider_records.each_with_object(Hash.new(0)) do |record, result|
          result[record['status'] || 'unknown'] += 1
        end
        target = Utils.number(provider['traffic_percentage'])
        share = Utils.percentage(count, records.length)
        observed_approval = Utils.percentage(statuses['approved'], count)

        [name, {
          'count' => count,
          'share_pct' => share,
          'target_pct' => target && Utils.clean_number(target),
          'deviation_pp' => target && share && Utils.clean_number(share - target),
          'amount' => Utils.clean_number(amount),
          'volume_share_pct' => Utils.percentage(amount, total_amount),
          'target_volume_share_pct' => Utils.number(provider['volume_share_pct']),
          'approved' => statuses['approved'],
          'rejected' => statuses['rejected'],
          'expired' => statuses['expired'],
          'unknown' => statuses['unknown'],
          'approval_rate_pct' => observed_approval,
          'snapshot_conversion_24h_pct' => Utils.number(provider['conversion_24h']) &&
            Utils.clean_number(Utils.number(provider['conversion_24h']) * 100),
          'latency' => latency_stats(provider_records.map { |record| record['latency_sec'] })
        }]
      end
    end

    def status_summary(records)
      counts = records.each_with_object(Hash.new(0)) do |record, result|
        result[record['status'] || 'unknown'] += 1
      end
      statuses = (BASE_STATUSES + counts.keys).uniq
      statuses.to_h do |status|
        [status, {
          'count' => counts[status],
          'share_pct' => Utils.percentage(counts[status], records.length)
        }]
      end
    end

    def latency_summary(records)
      result = latency_stats(records.map { |record| record['latency_sec'] })
      result['by_status'] = records.group_by { |record| record['status'] || 'unknown' }
        .sort.to_h.transform_values do |status_records|
          latency_stats(status_records.map { |record| record['latency_sec'] })
        end
      result
    end

    def latency_stats(values)
      values = values.compact.map(&:to_f)
      return {
        'count' => 0,
        'avg_sec' => nil,
        'p50_sec' => nil,
        'p95_sec' => nil,
        'min_sec' => nil,
        'max_sec' => nil
      } if values.empty?

      {
        'count' => values.length,
        'avg_sec' => Utils.clean_number(values.sum / values.length),
        'p50_sec' => Utils.median(values),
        'p95_sec' => Utils.percentile(values, 0.95),
        'min_sec' => Utils.clean_number(values.min),
        'max_sec' => Utils.clean_number(values.max)
      }
    end

    def skip_reasons(latest_events)
      counts = Hash.new(0)
      latest_events.each do |event|
        attempts = event.dig('routing_decision', 'attempts')
        next unless attempts.is_a?(Array)

        attempts.each do |attempt|
          next unless attempt['decision'] == 'skipped'

          counts[attempt['reason'] || 'unknown'] += 1
        end
      end
      counts.sort.to_h
    end

    def utilization_for_providers
      @providers.to_h do |provider|
        used = Utils.number(provider['daily_approved_amount']) || 0.0
        limit = Utils.number(provider['daily_amount_limit'])
        [provider['payment_system'], {
          'used' => Utils.clean_number(used),
          'limit' => limit && Utils.clean_number(limit),
          'remaining' => limit && Utils.clean_number(limit - used),
          'utilization_pct' => limit && Utils.percentage(used, limit)
        }]
      end
    end

    def provider_state
      @providers.to_h do |provider|
        count = Utils.number(provider['in_progress_count']) || 0.0
        count_limit = Utils.number(provider['in_progress_count_limit'])
        amount = Utils.number(provider['in_progress_amount']) || 0.0
        amount_limit = Utils.number(provider['in_progress_amount_limit'])

        [provider['payment_system'], {
          'status' => provider['status'],
          'priority' => provider['priority'],
          'available_requisites' => provider['available_requisites'],
          'in_progress_count' => Utils.clean_number(count),
          'in_progress_count_limit' => count_limit && Utils.clean_number(count_limit),
          'in_progress_count_utilization_pct' => count_limit && Utils.percentage(count, count_limit),
          'in_progress_amount' => Utils.clean_number(amount),
          'in_progress_amount_limit' => amount_limit && Utils.clean_number(amount_limit),
          'in_progress_amount_utilization_pct' => amount_limit && Utils.percentage(amount, amount_limit)
        }]
      end
    end

    def period_window(records)
      times = records.filter_map { |record| Utils.parse_time(record['created_at']) }
      return { 'from' => nil, 'to' => nil } if times.empty?

      { 'from' => times.min.iso8601, 'to' => times.max.iso8601 }
    end

    def period_label(records)
      window = period_window(records)
      return 'unknown' unless window['from'] && window['to']

      first_date = window['from'][0, 10]
      last_date = window['to'][0, 10]
      first_date == last_date ? first_date : "#{first_date}..#{last_date}"
    end

    def data_quality(records, latest_events)
      history_times = normalized_history.filter_map { |record| Utils.parse_time(record['created_at']) }
      descents = history_times.each_cons(2).count { |left, right| right < left }
      blank_card_brand = records.count { |record| record['card_brand'].nil? || record['card_brand'].to_s.empty? }
      bank_mismatches = normalized_history.count { |record| current_bank_rule_mismatch?(record) }
      unique_routing_ids = @routing_events.filter_map do |event|
        event['operation_id'] || event.dig('operation', 'operation_id')
      end.uniq.length
      history_ids = @history_rows.map { |row| row['operation_id'] }
      routing_ids = latest_events.filter_map do |event|
        event['operation_id'] || event.dig('operation', 'operation_id')
      end
      overlap = (history_ids & routing_ids).length
      invalid_timestamps = records.count { |record| Utils.parse_time(record['created_at']).nil? }
      invalid_amounts = records.count { |record| record['amount'].nil? || record['amount'].negative? }
      unknown_providers = records.count do |record|
        record['payment_system'].nil? || !@provider_by_name.key?(record['payment_system'])
      end
      unknown_statuses = records.count { |record| !BASE_STATUSES.include?(record['status']) }
      duplicate_history_ids = history_ids.length - history_ids.compact.uniq.length
      snapshot_time = Utils.parse_time(@provider_data['snapshot_at'])
      snapshot_after_history = snapshot_time && history_times.any? && snapshot_time.to_date > history_times.max.to_date
      database_orphans = @source_metadata['orphans'] || {}
      orphan_count = database_orphans.values.sum(&:to_i)

      warnings = []
      warnings << "проверка целостности SQLite вернула #{@source_metadata['integrity_check']}" if @source_metadata['integrity_check'] && @source_metadata['integrity_check'] != 'ok'
      warnings << 'в схеме SQLite не объявлены внешние ключи; ссылочная целостность контролируется приложением' if @source_metadata['foreign_key_definitions'].to_i.zero?
      warnings << "обнаружено #{orphan_count} записей с нарушенными логическими связями" if orphan_count.positive?
      warnings << "operations_history не отсортирован хронологически (обнаружено #{descents} переходов назад)" if descents.positive?
      if bank_mismatches.positive?
        warnings << "#{bank_mismatches} исторических назначений не соответствуют текущему снимку банков провайдеров; история используется для аналитики, а не для определения текущей доступности"
      end
      warnings << 'card_brand отсутствует у всех анализируемых операций' if records.any? && blank_card_brand == records.length
      warnings << 'у провайдеров не задан requests_per_minute_limit; аналитика по ограничениям частоты запросов недоступна' if @providers.none? { |provider| !provider['requests_per_minute_limit'].nil? }
      warnings << 'у провайдеров не задан volume_share_pct; отклонения от целевого распределения объёма недоступны' if @providers.none? { |provider| !provider['volume_share_pct'].nil? }
      warnings << "история содержит #{duplicate_history_ids} повторяющихся значений operation_id" if duplicate_history_ids.positive?
      warnings << "#{invalid_timestamps} операций имеют некорректное значение created_at" if invalid_timestamps.positive?
      warnings << "#{invalid_amounts} операций имеют отсутствующую или отрицательную сумму" if invalid_amounts.positive?
      warnings << "#{unknown_providers} операций ссылаются на неизвестного провайдера" if unknown_providers.positive?
      warnings << "#{unknown_statuses} операций имеют статус, отличный от approved/rejected/expired" if unknown_statuses.positive?
      if snapshot_after_history
        warnings << 'целевые значения распределения трафика получены из снимка, сделанного после периода истории; поэтому отклонения от целей являются ориентировочными и не представляют собой SLA-показатели за тот же период'
      end

      {
        'history_rows' => @history_rows.length,
        'routing_decision_rows' => @routing_events.length,
        'routing_unique_operations' => unique_routing_ids,
        'history_decision_overlap' => overlap,
        'analyzed_unique_operations' => records.length,
        'history_duplicate_operation_ids' => duplicate_history_ids,
        'invalid_timestamp_count' => invalid_timestamps,
        'invalid_amount_count' => invalid_amounts,
        'unknown_provider_count' => unknown_providers,
        'unknown_status_count' => unknown_statuses,
        'target_snapshot_after_history' => !!snapshot_after_history,
        'blank_card_brand_count' => blank_card_brand,
        'history_timestamp_backward_transitions' => descents,
        'history_current_bank_rule_mismatch_count' => bank_mismatches,
        'database_integrity' => @source_metadata['integrity_check'],
        'database_table_rows' => @source_metadata['table_rows'] || {},
        'database_orphans' => database_orphans,
        'foreign_key_definitions' => @source_metadata['foreign_key_definitions'],
        'warnings' => warnings
      }
    end

    def current_bank_rule_mismatch?(record)
      provider = @provider_by_name[record['payment_system']]
      return false unless provider

      banks = provider['banks'] || []
      return false if banks.empty?

      provider['exclude_banks'] ? banks.include?(record['bank']) : !banks.include?(record['bank'])
    end

    def recommendations(distribution, utilization)
      return ['Недостаточно операций для рекомендаций; накопить журнал новых решений'] if records_empty?(distribution)

      result = []
      @providers.each do |provider|
        name = provider['payment_system']
        target = Utils.number(provider['traffic_percentage'])
        next unless target&.positive?

        metrics = distribution.fetch(name)
        deviation = Utils.number(metrics['deviation_pp'])
        daily = utilization.fetch(name)
        daily_pct = Utils.number(daily['utilization_pct'])

        if daily_pct && daily_pct >= 90 && deviation && deviation <= -5
          result << "#{name}: фактическая доля #{metrics['share_pct']}% ниже цели #{metrics['target_pct']}%, но дневной лимит использован на #{daily['utilization_pct']}%; сначала увеличить доступную ёмкость или снизить целевую долю"
        elsif daily_pct && daily_pct >= 90
          result << "#{name}: дневной лимит использован на #{daily['utilization_pct']}%; снизить приоритет до обновления лимита или состояния"
        elsif deviation && deviation <= -5
          result << "#{name}: фактическая доля #{metrics['share_pct']}% ниже цели #{metrics['target_pct']}%; повысить вес count-share среди допустимых провайдеров"
        elsif deviation && deviation >= 5
          result << "#{name}: фактическая доля #{metrics['share_pct']}% выше цели #{metrics['target_pct']}%; снизить вес count-share среди допустимых провайдеров"
        end

        expired_share = Utils.percentage(metrics['expired'], metrics['count'])
        if metrics['count'] >= 10 && expired_share && expired_share >= 20
          result << "#{name}: доля expired составляет #{expired_share}%; проверить таймауты и латентность до увеличения трафика"
        end
      end
      result
    end

    def records_empty?(distribution)
      distribution.values.sum { |metrics| metrics['count'].to_i }.zero?
    end
  end

  class ReportWriter
    class << self
      def write(path, report, protected_roots: [])
        PathGuard.ensure_writable!(path, protected_roots)
        directory = File.dirname(path)
        FileUtils.mkdir_p(directory)
        temporary_path = "#{path}.tmp-#{Process.pid}"
        File.write(temporary_path, JSON.pretty_generate(report) + "\n", mode: 'w', encoding: 'UTF-8')
        FileUtils.mv(temporary_path, path, force: true)
        path
      ensure
        FileUtils.rm_f(temporary_path) if defined?(temporary_path) && temporary_path
      end
    end
  end
end
