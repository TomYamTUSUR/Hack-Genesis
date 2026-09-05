# frozen_string_literal: true

require_relative 'routing_analytics'

module RoutingAnalytics
  # Read-only adapter for the canonical schema and its minute-stat extensions.
  class CanonicalDatabaseSource
    PROVIDER_STATS_COLUMNS = %w[
      requests_last_minute actual_count_share_pct actual_volume_share_pct
      approved_volume_share_pct count_target_fulfillment_pct volume_target_fulfillment_pct
      count_share_gap_pp volume_share_gap_pp approval_rate_pct rejection_rate_pct
      expiration_rate_pct approved_amount_pct terminal_approval_rate_pct
      stats_calculated_at stats_window_sec
    ].freeze

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
      @database.busy_timeout = 5000
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
      @database&.close unless @database&.closed?
    end

    # All report sections must see the same committed database state.
    def snapshot
      @database.transaction { yield }
    rescue SQLite3::Exception => e
      raise Error, "unable to read database #{path}: #{e.message}"
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

    # Raw records retain attempt order and provenance; routing_events also contains
    # synthesized reference skips and must not be used to evaluate real cascades.
    def detail_inputs
      {
        decisions: rows('SELECT * FROM routing_decisions ORDER BY operation_id'),
        attempts: rows('SELECT * FROM routing_attempts ORDER BY operation_id, attempt_number, attempt_id'),
        references: rows('SELECT * FROM reference_decisions ORDER BY operation_id'),
        stored_skips: rows('SELECT * FROM provider_skip_reasons ORDER BY skip_reason_id')
      }
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
        optional_columns = table == 'providers' ? PROVIDER_STATS_COLUMNS : []
        unless actual_columns.reject { |column| optional_columns.include?(column) } == expected_columns
          missing = expected_columns - actual_columns
          unexpected = actual_columns - expected_columns - optional_columns
          raise Error, "#{path}: columns differ for #{table}; " \
            "missing=#{missing.join(',')} unexpected=#{unexpected.join(',')} (canonical column order required)"
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

  # Additional diagnostics share the main analyzer's operation deduplication:
  # a decision replaces history for the same operation, and pending rows stay out.
  class CanonicalReportDetails < Analyzer
    AMOUNT_BANDS = [
      ['0_1000', 0, 1000], ['1000_10000', 1000, 10_000],
      ['10000_50000', 10_000, 50_000], ['50000_100000', 50_000, 100_000],
      ['100000_plus', 100_000, nil]
    ].freeze
    FAILURE_REASONS = %w[provider_timeout provider_rejected provider_expired payout_failed].freeze
    FALLBACK_REASONS = %w[
      fallback fallback_candidate fallback_selected self_provider_fallback
      fallback_to_self_provider fallback_to_spacepayments
    ].freeze

    def initialize(details:, **inputs)
      super(**inputs)
      @details = details
      @decisions = details.fetch(:decisions)
      @decisions_by_id = @decisions.to_h { |row| [row['operation_id'], row] }
      @providers_by_id = @providers.to_h { |row| [row['payment_system_id'], row['payment_system']] }
      @attempt_groups = details.fetch(:attempts).group_by { |row| row['operation_id'] }
    end

    def sections(generated_at:)
      @records = combined_records(latest_routing_events)
      @generated_at = generated_at.getutc
      cascades = attempt_cascades
      {
        'routing_coverage' => routing_coverage(cascades),
        'reference_comparison' => reference_comparison,
        'attempt_cascades' => cascades,
        'segments' => segments,
        'period_comparison' => period_comparison,
        'skip_reason_sources' => skip_reason_sources,
        'freshness' => freshness
      }
    end

    private

    def routing_coverage(cascades)
      queue_ids = @pending_operations.map { |row| row['operation_id'] }.uniq
      decision_ids = @decisions_by_id.keys
      population = (queue_ids | decision_ids).length
      {
        'definition' => 'Population: distinct operation IDs in operations_queue UNION routing_decisions. History-only operations are excluded; awaiting_decision is not the pending_operations metric.',
        'status' => population.zero? ? 'no_operations' : (@decisions.empty? ? 'no_decisions' : 'available'),
        'operations_in_scope' => population,
        'queue_operations' => queue_ids.length,
        'with_decision' => decision_ids.length,
        'awaiting_decision' => (queue_ids - decision_ids).length,
        'decision_coverage_pct' => Utils.percentage(decision_ids.length, population),
        'without_selected_provider' => @decisions.count { |row| row['selected_payment_system_id'].nil? },
        'unknown_selected_provider' => @decisions.count do |row|
          id = row['selected_payment_system_id']
          !id.nil? && !@providers_by_id.key?(id)
        end,
        'with_known_selected_provider' => @decisions.count { |row| @providers_by_id.key?(row['selected_payment_system_id']) },
        'fallback_operations' => cascades['fallback_operations'],
        'fallback_share_of_decisions_pct' => @decisions.empty? ? nil : Utils.percentage(cascades['fallback_operations'], decision_ids.length),
        'fallback_unclassified_operations' => cascades['unclassified_operations']
      }
    end

    def reference_comparison
      rows = @details.fetch(:references).map do |reference|
        decision = @decisions_by_id[reference['operation_id']]
        required = reference['required_payment_system_id']
        actual = decision && decision['selected_payment_system_id']
        outcome = if required.nil? || !@providers_by_id.key?(required)
                    'invalid_reference'
                  elsif decision.nil?
                    'awaiting_decision'
                  elsif required == actual
                    'match'
                  else
                    'mismatch'
                  end
        {
          'operation_id' => reference['operation_id'], 'outcome' => outcome,
          'required_payment_system_id' => required, 'required_provider' => @providers_by_id[required],
          'selected_payment_system_id' => actual, 'selected_provider' => @providers_by_id[actual],
          'reference_reason' => reference['reason']
        }
      end
      counts = rows.map { |row| row['outcome'] }.tally
      matched = counts.fetch('match', 0)
      mismatched = counts.fetch('mismatch', 0)
      compared = matched + mismatched
      {
        'definition' => 'Compare provider IDs only for valid references with a recorded decision; missing decisions are not mismatches. Reference agreement does not validate all runtime constraints.',
        'status' => rows.empty? ? 'no_references' : (compared.zero? ? 'no_comparable_decisions' : 'available'),
        'reference_operations' => rows.length, 'compared_operations' => compared,
        'matched' => matched, 'mismatched' => mismatched,
        'awaiting_decision' => counts.fetch('awaiting_decision', 0),
        'invalid_references' => counts.fetch('invalid_reference', 0),
        'match_rate_pct' => Utils.percentage(matched, compared),
        'comparison_coverage_pct' => Utils.percentage(compared, rows.length),
        'mismatches' => rows.select { |row| row['outcome'] == 'mismatch' },
        'uncompared' => rows.reject { |row| %w[match mismatch].include?(row['outcome']) }
      }
    end

    def cascade_classification(decision, attempts)
      # Static hard-constraint skips alone never imply a failed dispatch/fallback.
      selected = attempts.select { |row| row['decision'] == 'selected' }
      final_id = decision['selected_payment_system_id']
      explicit_fallback = selected.any? do |row|
        @providers_by_id.key?(final_id) && row['payment_system_id'] == final_id && FALLBACK_REASONS.include?(row['reason'])
      end
      return 'fallback' if @providers_by_id[final_id] == 'spacepayments' || explicit_fallback

      ordered = attempts.any? && attempts.all? { |row| row['attempt_number'].is_a?(Integer) && row['attempt_number'].positive? }
      numbers = attempts.map { |row| row['attempt_number'] }
      ordered &&= numbers.sort == (1..attempts.length).to_a
      return 'unclassified' unless ordered && @providers_by_id.key?(final_id) && selected.last&.fetch('payment_system_id') == final_id

      last_number = selected.last['attempt_number']
      previous_failure = attempts.any? do |row|
        row['attempt_number'] < last_number && FAILURE_REASONS.include?(row['reason'])
      end
      return 'fallback' if selected.length > 1 || previous_failure
      return 'unclassified' unless attempts.all? { |row| %w[selected skipped].include?(row['decision']) }

      'first_choice'
    end

    def attempt_cascades
      classified = @decisions.map do |decision|
        attempts = @attempt_groups.fetch(decision['operation_id'], [])
        [decision, attempts, cascade_classification(decision, attempts)]
      end
      first = classified.select { |_, _, kind| kind == 'first_choice' }
      fallback = classified.select { |_, _, kind| kind == 'fallback' }
      with_attempts = classified.reject { |_, attempts, _| attempts.empty? }
      approved = ->(group) { group.count { |decision, _, _| decision['simulated_result'] == 'approved' } }
      recorded = with_attempts.flat_map { |_, attempts, _| attempts }
      {
        'status' => @decisions.empty? ? 'no_decisions' : (with_attempts.empty? ? 'no_attempt_logs' : 'available_with_caveats'),
        'definitions' => {
          'attempt_count' => 'Logged evaluation steps, including skipped providers; not HTTP requests. Orphans and synthesized reference skips are excluded.',
          'first_choice' => 'Exactly one selected provider matching the final choice in a contiguous ordered log, without explicit fallback/failure evidence. Static eligibility skips do not count as dispatch failures.',
          'fallback' => 'spacepayments final choice, explicit fallback reason, multiple selected providers, or a recorded failure before the final choice. Classification is based on retained logs, whose completeness is unverified.',
          'failure_reasons' => FAILURE_REASONS,
          'explicit_fallback_reasons' => FALLBACK_REASONS,
          'success' => 'simulated_result = approved; no per-attempt payment outcome or verified live/simulation provenance is stored.',
          'first_attempt_success_pct' => 'Approved first-choice operations / all classified operations.',
          'cohort_approval_pct' => 'Approved operations / operations within the corresponding first-choice or fallback cohort.'
        },
        'operations_with_attempt_logs' => with_attempts.length,
        'operations_without_attempt_logs' => @decisions.length - with_attempts.length,
        'attempt_log_coverage_pct' => Utils.percentage(with_attempts.length, @decisions.length),
        'recorded_attempts' => recorded.length,
        'average_recorded_attempts' => with_attempts.empty? ? nil : Utils.clean_number(recorded.length.to_f / with_attempts.length),
        'attempt_count_distribution' => with_attempts.map { |_, attempts, _| attempts.length }.tally.sort.to_h.transform_keys(&:to_s),
        'attempt_decisions' => recorded.map { |row| row['decision'] || 'unknown' }.tally.sort.to_h,
        'orphan_attempt_rows' => @details[:attempts].count { |row| !@decisions_by_id.key?(row['operation_id']) },
        'first_choice_operations' => first.length, 'first_choice_approved' => approved.call(first),
        'first_choice_approval_pct' => Utils.percentage(approved.call(first), first.length),
        'first_attempt_success_pct' => Utils.percentage(approved.call(first), first.length + fallback.length),
        'fallback_operations' => fallback.length, 'fallback_approved' => approved.call(fallback),
        'fallback_approval_pct' => Utils.percentage(approved.call(fallback), fallback.length),
        'fallback_statuses' => fallback.map { |decision, _, _| decision['simulated_result'] || 'unknown' }.tally.sort.to_h,
        'unclassified_operations' => classified.count { |_, _, kind| kind == 'unclassified' },
        'classification_coverage_pct' => Utils.percentage(first.length + fallback.length, @decisions.length),
        'network_attempt_count' => nil
      }
    end

    def metric_summary(records)
      amounts = records.filter_map { |row| valid_amount(row['amount']) }
      statuses = records.map { |row| row['status'] || 'unknown' }.tally
      {
        'count' => records.length,
        'amount' => amounts.empty? && records.any? ? nil : Utils.clean_number(amounts.sum),
        'invalid_amount_count' => records.length - amounts.length,
        'statuses' => statuses.sort.to_h,
        'approval_rate_pct' => Utils.percentage(statuses.fetch('approved', 0), records.length),
        'latency' => latency_stats(records.map { |row| valid_amount(row['latency_sec']) }),
        'sources' => records.map { |row| row['source'] }.tally.sort.to_h
      }
    end

    def cohort_summary(records)
      summary = metric_summary(records)
      summary['providers'] = records.group_by { |row| row['payment_system'] || 'unknown' }.sort.to_h.transform_values do |group|
        metrics = metric_summary(group)
        metrics.merge(
          'share_pct' => Utils.percentage(group.length, records.length),
          'volume_share_pct' => metrics['amount'].nil? || summary['amount'].nil? ? nil : Utils.percentage(metrics['amount'], summary['amount'])
        )
      end
      summary
    end

    def valid_amount(value)
      number = Utils.number(value)
      number if number&.finite? && number >= 0
    end

    def segments
      by_amount = AMOUNT_BANDS.to_h { |name, _, _| [name, []] }.merge('unknown' => [])
      @records.each do |row|
        amount = valid_amount(row['amount'])
        band = amount && AMOUNT_BANDS.find { |_, lower, upper| amount >= lower && (upper.nil? || amount < upper) }
        by_amount[band ? band.first : 'unknown'] << row
      end
      {
        'definition' => 'Same deduplicated population as total_operations; decisions override history. Approval denominator is all operations in the segment. Provider shares are within each segment. Amounts use database units; invalid amounts/latencies are excluded from numeric sums/statistics and invalid amounts are counted.',
        'window' => observation_window(@records),
        'amount_band_boundaries' => AMOUNT_BANDS.to_h { |name, lower, upper| [name, { 'min_inclusive' => lower, 'max_exclusive' => upper }] },
        'by_bank' => @records.group_by { |row| row['bank'].to_s.strip.empty? ? 'unknown' : row['bank'] }.sort.to_h.transform_values { |group| cohort_summary(group) },
        'by_amount' => by_amount.transform_values { |group| cohort_summary(group) }
      }
    end

    # Normalize explicit offsets to UTC; timezone-free SQLite dates are treated as UTC.
    def timestamp(value)
      return nil if value.nil? || value.to_s.strip.empty?

      text = value.to_s.strip
      text += ' UTC' unless text.match?(/(?:Z|UTC|[+-]\d{2}:?\d{2})\z/i)
      Time.parse(text).getutc
    rescue ArgumentError
      nil
    end

    def observation_window(records, field = 'created_at')
      times = records.filter_map { |row| timestamp(row[field]) }
      {
        'from' => times.min&.iso8601(6), 'to' => times.max&.iso8601(6),
        'invalid_or_missing_timestamps' => records.length - times.length
      }
    end

    def metric_changes(current, previous)
      values = {
        'count' => [current['count'], previous['count']],
        'amount' => [current['amount'], previous['amount']],
        'approval_rate' => [current['approval_rate_pct'], previous['approval_rate_pct']],
        'avg_latency_sec' => [current.dig('latency', 'avg_sec'), previous.dig('latency', 'avg_sec')],
        'p95_latency_sec' => [current.dig('latency', 'p95_sec'), previous.dig('latency', 'p95_sec')]
      }
      values.to_h do |name, (now, before)|
        difference = now && before ? Utils.clean_number(now - before) : nil
        [name, name == 'approval_rate' ? { 'delta_pp' => difference } : {
          'delta' => difference, 'change_pct' => difference.nil? || before.to_f.zero? ? nil : Utils.percentage(difference, before)
        }]
      end
    end

    def period_comparison
      dated = @records.filter_map { |row| time = timestamp(row['created_at']); [time, row] if time && time < @generated_at }
      result = {
        'timezone' => 'UTC',
        'definition' => 'Latest observed UTC day before generated_at versus the immediately preceding day. Completed days use [00:00, next 00:00); today uses [00:00, generated_at) and the same elapsed interval yesterday. No substitution of an older nonadjacent day.',
        'caveats' => ['Source coverage/completeness is not recorded; no observations do not prove zero activity.', 'Uses currently stored statuses and decision overrides, not reconstructed past outcomes.'],
        'excluded_invalid_timestamp_count' => @records.count { |row| timestamp(row['created_at']).nil? },
        'excluded_at_or_after_generated_at_count' => @records.count { |row| time = timestamp(row['created_at']); time && time >= @generated_at },
        'status' => 'no_dated_operations', 'partial_day' => nil,
        'current' => nil, 'previous' => nil, 'changes' => nil, 'provider_changes' => {}
      }
      return result if dated.empty?

      latest = dated.map(&:first).max
      start_at = Time.utc(latest.year, latest.month, latest.day)
      end_at = [start_at + 86_400, @generated_at].min
      groups = [[start_at, end_at], [start_at - 86_400, end_at - 86_400]].map do |lower, upper|
        selected = dated.select { |time, _| time >= lower && time < upper }.map(&:last)
        cohort_summary(selected).merge('from_inclusive' => lower.iso8601(6), 'to_exclusive' => upper.iso8601(6), 'duration_sec' => Utils.clean_number(upper - lower))
      end
      current, previous = groups
      result.merge!('current' => current, 'previous' => previous, 'partial_day' => end_at < start_at + 86_400)
      if previous['count'].zero?
        result['status'] = 'no_previous_period_observations'
        return result
      end

      result['status'] = 'available_with_caveats'
      result['changes'] = metric_changes(current, previous)
      result['provider_changes'] = (current['providers'].keys | previous['providers'].keys).sort.to_h do |name|
        now = current['providers'][name] || metric_summary([]).merge('share_pct' => 0, 'volume_share_pct' => current['amount'].to_f.zero? ? nil : 0)
        before = previous['providers'][name] || metric_summary([]).merge('share_pct' => 0, 'volume_share_pct' => previous['amount'].to_f.zero? ? nil : 0)
        changes = metric_changes(now, before)
        %w[share_pct volume_share_pct].each do |key|
          changes["#{key.delete_suffix('_pct')}_delta_pp"] = now[key] && before[key] ? Utils.clean_number(now[key] - before[key]) : nil
        end
        [name, changes]
      end
      result
    end

    def skip_keys(rows)
      rows.map { |row| [row['operation_id'], row['payment_system_id'], row['reason'] || 'unknown'] }.uniq
    end

    def skip_reason_sources
      observed = skip_keys(@details[:attempts].select { |row| row['decision'] == 'skipped' })
      stored = skip_keys(@details[:stored_skips])
      {
        'definition' => 'Counts use distinct operation/provider/reason tuples. Source-separated counts overlap and must not be added. Only routing_attempts is a recorded routing trace; provider_skip_reasons has no reliable fact/reference provenance flag.',
        'routing_attempts' => { 'distinct_skips' => observed.length, 'reasons' => observed.map(&:last).tally.sort.to_h },
        'stored_reference_or_unclassified' => { 'distinct_skips' => stored.length, 'reasons' => stored.map(&:last).tally.sort.to_h },
        'overlap_count' => (observed & stored).length,
        'stored_only_count' => (stored - observed).length,
        'combined_distinct_count' => (observed | stored).length
      }
    end

    def source_freshness(rows, field = 'created_at')
      window = observation_window(rows, field)
      latest = timestamp(window['to'])
      window.merge(
        'rows' => rows.length, 'timestamp_field' => field,
        'last_observation_age_sec' => latest ? Utils.clean_number(@generated_at - latest) : nil,
        'future_timestamp_count' => rows.count { |row| time = timestamp(row[field]); time && time > @generated_at },
        'completeness_verified' => false
      )
    end

    def freshness
      {
        'evaluated_at' => @generated_at.iso8601(6), 'timezone' => 'UTC',
        'definition' => 'Age is measured from stored event/reference times, not ingestion time. Negative age identifies future timestamps. Timezone-free dates are interpreted as UTC. No freshness SLA or ingestion watermark is available.',
        'sources' => {
          'operations_history' => source_freshness(@history_rows),
          'operations_queue' => source_freshness(@pending_operations),
          'routing_decisions' => source_freshness(@decisions),
          'routing_attempts' => source_freshness(@details[:attempts]),
          'provider_skip_reasons' => source_freshness(@details[:stored_skips]),
          'reference_decisions' => { 'rows' => @details[:references].length, 'as_of' => nil, 'reason' => 'No reference timestamp is stored.' },
          'providers' => { 'as_of' => nil, 'reason' => 'Full snapshot/target/limit timestamp is not stored.' }
        },
        'provider_metric_windows' => @providers.to_h do |provider|
          time = timestamp(provider['stats_calculated_at'])
          seconds = valid_amount(provider['stats_window_sec'])
          seconds = nil if seconds&.zero?
          [provider['payment_system'], {
            'minute_from_exclusive' => time && seconds ? (time - seconds).iso8601(6) : nil,
            'minute_to_inclusive' => time&.iso8601(6), 'window_sec' => seconds,
            'conversion_24h_from_exclusive' => time ? (time - 86_400).iso8601(6) : nil,
            'last_calculation_age_sec' => time ? Utils.clean_number(@generated_at - time) : nil
          }]
        end,
        'blocks' => {
          'distribution_status_latency_segments' => { 'source' => 'operations_history + routing_decisions; decision wins on duplicate operation_id', 'window' => observation_window(@records), 'outcome_provenance' => 'History status plus simulated_result from decisions; live versus sample origin is not stored.' },
          'pending_queue' => { 'source' => 'operations_queue excluding IDs present in history or decisions', 'window' => observation_window(unprocessed_pending_operations(latest_routing_events)) },
          'routing_coverage_reference_comparison_cascades' => { 'source' => 'queue, raw decisions, raw attempts and references; all retained rows', 'decision_window' => observation_window(@decisions), 'reference_as_of' => nil },
          'skip_reasons' => { 'source' => 'See skip_reason_sources; legacy skip_reasons remains their deduplicated union.', 'window' => observation_window(@details[:stored_skips] + @details[:attempts].select { |row| row['decision'] == 'skipped' }) },
          'provider_state_utilization_recommendations' => { 'source' => 'Current stored provider fields; snapshot freshness is unknown. Minute metrics have separate windows above.', 'as_of' => nil, 'recommendation_period' => period_label(latest_day_records(@records)) },
          'period_comparison' => { 'source' => 'Same deduplicated operations; UTC windows are explicit in period_comparison.' }
        }
      }
    end
  end

  class CanonicalDatabaseAnalytics
    def initialize(path)
      @source = CanonicalDatabaseSource.new(path)
    end

    def report(generated_at: Time.now)
      @source.snapshot do
        inputs = @source.analysis_inputs
        result = Analyzer.new(**inputs).report(generated_at: generated_at)
        result['skip_reasons'] = @source.skip_reason_counts
        providers = inputs.fetch(:provider_data).fetch('providers')
        providers.each do |provider|
          # Keep persisted minute metrics separate from distribution over all history.
          stats = provider.select { |key, _| CanonicalDatabaseSource::PROVIDER_STATS_COLUMNS.include?(key) }
          next if stats.empty?

          result['provider_state'].fetch(provider.fetch('payment_system'))['minute_stats'] = stats
        end
        result['source']['definitions'] = {
          'provider_snapshot' => 'Full provider snapshot time is unknown; stats_calculated_at dates only recalculated metrics.',
          'minute_stats' => 'Persisted provider metrics; window ends at stats_calculated_at and lasts stats_window_sec seconds. Not recomputed by this report.',
          'in_progress' => 'After the minute-stat update, in_progress_count/amount count all applications in that minute, not concurrent unfinished operations.',
          'skip_reasons' => 'Distinct operation/provider/reason combinations across routing_attempts and provider_skip_reasons; the latter may contain imported reference expectations.'
        }
        warnings = result.fetch('data_quality').fetch('warnings')
        warnings << 'Время полного снимка providers неизвестно; цели и лимиты могут относиться к другому периоду, чем история. Рекомендации ориентировочные.'
        if providers.any? { |provider| provider['stats_calculated_at'] }
          warnings << 'Минутные показатели providers сохранены отдельным пересчётом; их окно указано в minute_stats и может не совпадать с периодом отчёта. in_progress_* отражает весь минутный поток.'
        end
        if result.dig('source', 'table_rows', 'routing_decisions').zero?
          warnings << 'routing_decisions пуста: отчёт описывает историю и очередь, фактические результаты новой маршрутизации отсутствуют.'
        end
        if result.dig('source', 'table_rows', 'provider_skip_reasons').positive?
          warnings << 'skip_reasons включает provider_skip_reasons: импорт мог записать туда эталонные ожидания, а не фактические пропуски.'
        end
        result.merge!(CanonicalReportDetails.new(**inputs, details: @source.detail_inputs).sections(generated_at: generated_at))
        result
      end
    end

    def close
      @source.close
    end
  end
end
