# frozen_string_literal: true

require_relative 'routing_analytics'

module RoutingAnalytics
  # Read-only adapter for the canonical eight-table database schema.
  class CanonicalDatabaseSource
    TABLE_COLUMNS = {
      'operations_queue' => %w[
        operation_id created_at amount bank card_brand
        payout_requisite_sbp_phone payout_requisite_bank_name
      ],
      'providers' => %w[
        payment_system_id payment_system status traffic_percentage priority
        limit_amount_min limit_amount_max daily_amount_limit daily_approved_amount
        in_progress_count_limit in_progress_count in_progress_amount_limit
        in_progress_amount available_requisites conversion_24h avg_latency_sec
        banks exclude_banks provider_margin_pct merchant_margin_pct
        allow_negative_agreement note volume_share_pct requests_per_minute_limit
        daily_turnover_min daily_turnover_max
      ],
      'operations_history' => %w[
        operation_id created_at amount bank card_brand payment_system_id status latency_sec
      ],
      'routing_decisions' => %w[
        operation_id selected_payment_system_id simulated_result latency_sec created_at
      ],
      'routing_attempts' => %w[
        attempt_id operation_id payment_system_id attempt_number decision reason created_at
      ],
      'eligible_providers' => %w[
        operation_id payment_system_id is_eligible checked_at
      ],
      'provider_skip_reasons' => %w[
        skip_reason_id operation_id payment_system_id reason created_at
      ],
      'reference_decisions' => %w[
        operation_id required_payment_system_id reason
      ]
    }.freeze

    EXPECTED_FOREIGN_KEYS = {
      'operations_queue' => [],
      'providers' => [],
      'operations_history' => [
        %w[payment_system_id providers payment_system_id]
      ],
      'routing_decisions' => [
        %w[operation_id operations_queue operation_id],
        %w[selected_payment_system_id providers payment_system_id]
      ],
      'routing_attempts' => [
        %w[operation_id routing_decisions operation_id],
        %w[payment_system_id providers payment_system_id]
      ],
      'eligible_providers' => [
        %w[operation_id operations_queue operation_id],
        %w[payment_system_id providers payment_system_id]
      ],
      'provider_skip_reasons' => [
        %w[operation_id operations_queue operation_id],
        %w[payment_system_id providers payment_system_id]
      ],
      'reference_decisions' => [
        %w[operation_id operations_queue operation_id],
        %w[required_payment_system_id providers payment_system_id]
      ]
    }.freeze

    attr_reader :path

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
    rescue Error
      close
      raise
    rescue SQLite3::Exception => e
      close
      raise Error, "unable to read database #{@path}: #{e.message}"
    end

    def close
      @database&.close
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

    def skip_reason_counts
      rows(<<~SQL).to_h { |row| [row['reason'], row['count']] }
        SELECT reason, COUNT(*) AS count
        FROM (
          SELECT operation_id, payment_system_id, COALESCE(reason, 'unknown') AS reason
          FROM provider_skip_reasons
          UNION
          SELECT operation_id, payment_system_id, COALESCE(reason, 'unknown') AS reason
          FROM routing_attempts
          WHERE decision = 'skipped'
        )
        GROUP BY reason
        ORDER BY reason
      SQL
    end

    private

    def validate_schema!
      actual_tables = rows(<<~SQL).map { |row| row['name'] }.sort
        SELECT name
        FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
      SQL
      expected_tables = TABLE_COLUMNS.keys.sort
      unless actual_tables == expected_tables
        raise Error,
          "#{path}: database tables differ from canonical schema; " \
          "expected=#{expected_tables.join(',')} actual=#{actual_tables.join(',')}"
      end

      TABLE_COLUMNS.each do |table, expected_columns|
        actual_columns = rows("PRAGMA table_info(#{table})").map { |row| row['name'] }
        unless actual_columns == expected_columns
          raise Error, "#{path}: columns differ for #{table}"
        end

        actual_foreign_keys = rows("PRAGMA foreign_key_list(#{table})").map do |row|
          [row['from'], row['table'], row['to']]
        end.sort
        expected_foreign_keys = EXPECTED_FOREIGN_KEYS.fetch(table).sort
        unless actual_foreign_keys == expected_foreign_keys
          raise Error, "#{path}: foreign keys differ for #{table}"
        end
      end
    end

    def provider_data
      providers = rows('SELECT * FROM providers ORDER BY priority, payment_system_id').map do |provider|
        provider['banks'] = parse_banks(provider['banks'])
        provider['exclude_banks'] = provider['exclude_banks'].to_i == 1
        provider['allow_negative_agreement'] = provider['allow_negative_agreement'].to_i == 1
        provider
      end

      {
        'snapshot_at' => nil,
        'gateway' => nil,
        'merchant' => nil,
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
      attempts_by_operation = attempts.group_by { |attempt| attempt['operation_id'] }
      rows(<<~SQL).map do |row|
        SELECT d.operation_id, d.created_at AS decision_created_at,
               d.simulated_result, d.latency_sec,
               selected.payment_system AS selected_provider,
               COALESCE(q.created_at, h.created_at, d.created_at) AS operation_created_at,
               COALESCE(q.amount, h.amount) AS amount,
               COALESCE(q.bank, h.bank) AS bank,
               COALESCE(q.card_brand, h.card_brand) AS card_brand
        FROM routing_decisions d
        LEFT JOIN providers selected
          ON selected.payment_system_id = d.selected_payment_system_id
        LEFT JOIN operations_queue q ON q.operation_id = d.operation_id
        LEFT JOIN operations_history h ON h.operation_id = d.operation_id
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
            'attempts' => attempts_by_operation.fetch(row['operation_id'], []),
            'simulated_result' => row['simulated_result'],
            'latency_sec' => row['latency_sec']
          }
        }
      end
    end

    def attempts
      normalized = rows(<<~SQL).map do |row|
        SELECT a.operation_id, p.payment_system AS provider, a.decision, a.reason,
               a.attempt_number
        FROM routing_attempts a
        LEFT JOIN providers p ON p.payment_system_id = a.payment_system_id
        ORDER BY a.operation_id, a.attempt_number
      SQL
        {
          'operation_id' => row['operation_id'],
          'provider' => row['provider'],
          'decision' => row['decision'],
          'reason' => row['reason'],
          'attempt_number' => row['attempt_number']
        }
      end

      known_skips = normalized.select { |attempt| attempt['decision'] == 'skipped' }
        .to_h { |attempt| [[attempt['operation_id'], attempt['provider'], attempt['reason']], true] }
      rows(<<~SQL).each do |row|
        SELECT s.operation_id, p.payment_system AS provider, s.reason
        FROM provider_skip_reasons s
        LEFT JOIN providers p ON p.payment_system_id = s.payment_system_id
        ORDER BY s.operation_id, s.skip_reason_id
      SQL
        key = [row['operation_id'], row['provider'], row['reason']]
        next if known_skips[key]

        normalized << {
          'operation_id' => row['operation_id'],
          'provider' => row['provider'],
          'decision' => 'skipped',
          'reason' => row['reason'],
          'attempt_number' => nil
        }
      end

      normalized.map do |attempt|
        attempt.reject { |key, _value| %w[operation_id attempt_number].include?(key) }
          .merge('operation_id' => attempt['operation_id'])
      end
    end

    def source_metadata
      foreign_key_count = TABLE_COLUMNS.keys.sum do |table|
        rows("PRAGMA foreign_key_list(#{table})").length
      end
      {
        'type' => 'sqlite',
        'database' => path,
        'integrity_check' => first_value('PRAGMA integrity_check'),
        'foreign_key_definitions' => foreign_key_count,
        'table_rows' => TABLE_COLUMNS.keys.to_h do |table|
          [table, first_value("SELECT COUNT(*) FROM #{table}")]
        end,
        'orphans' => orphan_counts
      }
    end

    def orphan_counts
      {
        'history_unknown_provider' => first_value(<<~SQL),
          SELECT COUNT(*) FROM operations_history h
          LEFT JOIN providers p ON p.payment_system_id = h.payment_system_id
          WHERE h.payment_system_id IS NOT NULL AND p.payment_system_id IS NULL
        SQL
        'decision_without_queue_operation' => first_value(<<~SQL),
          SELECT COUNT(*) FROM routing_decisions d
          LEFT JOIN operations_queue q ON q.operation_id = d.operation_id
          WHERE q.operation_id IS NULL
        SQL
        'decision_unknown_provider' => first_value(<<~SQL),
          SELECT COUNT(*) FROM routing_decisions d
          LEFT JOIN providers p ON p.payment_system_id = d.selected_payment_system_id
          WHERE d.selected_payment_system_id IS NOT NULL AND p.payment_system_id IS NULL
        SQL
        'attempt_without_decision' => first_value(<<~SQL),
          SELECT COUNT(*) FROM routing_attempts a
          LEFT JOIN routing_decisions d ON d.operation_id = a.operation_id
          WHERE a.operation_id IS NOT NULL AND d.operation_id IS NULL
        SQL
        'attempt_unknown_provider' => first_value(<<~SQL),
          SELECT COUNT(*) FROM routing_attempts a
          LEFT JOIN providers p ON p.payment_system_id = a.payment_system_id
          WHERE a.payment_system_id IS NOT NULL AND p.payment_system_id IS NULL
        SQL
        'eligible_without_queue_operation' => first_value(<<~SQL),
          SELECT COUNT(*) FROM eligible_providers e
          LEFT JOIN operations_queue q ON q.operation_id = e.operation_id
          WHERE q.operation_id IS NULL
        SQL
        'eligible_unknown_provider' => first_value(<<~SQL),
          SELECT COUNT(*) FROM eligible_providers e
          LEFT JOIN providers p ON p.payment_system_id = e.payment_system_id
          WHERE p.payment_system_id IS NULL
        SQL
        'skip_without_queue_operation' => first_value(<<~SQL),
          SELECT COUNT(*) FROM provider_skip_reasons s
          LEFT JOIN operations_queue q ON q.operation_id = s.operation_id
          WHERE s.operation_id IS NOT NULL AND q.operation_id IS NULL
        SQL
        'skip_unknown_provider' => first_value(<<~SQL),
          SELECT COUNT(*) FROM provider_skip_reasons s
          LEFT JOIN providers p ON p.payment_system_id = s.payment_system_id
          WHERE s.payment_system_id IS NOT NULL AND p.payment_system_id IS NULL
        SQL
        'reference_without_queue_operation' => first_value(<<~SQL),
          SELECT COUNT(*) FROM reference_decisions r
          LEFT JOIN operations_queue q ON q.operation_id = r.operation_id
          WHERE q.operation_id IS NULL
        SQL
        'reference_unknown_provider' => first_value(<<~SQL)
          SELECT COUNT(*) FROM reference_decisions r
          LEFT JOIN providers p ON p.payment_system_id = r.required_payment_system_id
          WHERE r.required_payment_system_id IS NOT NULL AND p.payment_system_id IS NULL
        SQL
      }
    end

    def rows(sql, bindings = [])
      @database.execute(sql, bindings).map do |row|
        row.each_with_object({}) do |(key, value), result|
          result[key] = value if key.is_a?(String)
        end
      end
    end

    def first_value(sql, bindings = [])
      @database.get_first_value(sql, bindings)
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

  class CanonicalDatabaseAnalytics
    def initialize(path)
      @source = CanonicalDatabaseSource.new(path)
    end

    def report(generated_at: Time.now)
      result = Analyzer.new(**@source.analysis_inputs).report(generated_at: generated_at)
      result['skip_reasons'] = @source.skip_reason_counts
      result
    end

    def close
      @source.close
    end
  end
end
