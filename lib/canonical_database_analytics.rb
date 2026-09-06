# frozen_string_literal: true

require_relative 'routing_analytics'

module RoutingAnalytics
  class CanonicalDatabaseSource
    PROVIDER_STATS_COLUMNS = %w[
      requests_last_minute actual_count_share_pct actual_volume_share_pct
      approved_volume_share_pct count_target_fulfillment_pct volume_target_fulfillment_pct
      count_share_gap_pp volume_share_gap_pp approval_rate_pct rejection_rate_pct
      expiration_rate_pct approved_amount_pct terminal_approval_rate_pct
      stats_calculated_at stats_window_sec
    ].freeze

    ROUTING_COLUMNS = {
      'providers' => %w[daily_approved_date daily_utc_offset],
      'routing_decisions' => %w[explanation],
      'routing_attempts' => %w[details dispatched_at]
    }.freeze

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
        daily_turnover_min daily_turnover_max preferred_range_min preferred_range_max
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

    def detail_inputs
      {
        decisions: rows('SELECT * FROM routing_decisions ORDER BY operation_id'),
        queue: pending_operations,
        attempts: rows('SELECT * FROM routing_attempts ORDER BY operation_id, attempt_number, attempt_id'),
        eligibility: rows('SELECT * FROM eligible_providers ORDER BY operation_id, payment_system_id'),
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
        optional_columns = (table == 'providers' ? PROVIDER_STATS_COLUMNS : []) + ROUTING_COLUMNS.fetch(table, [])
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
        SELECT d.*, d.created_at AS decision_created_at,
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
            'latency_sec' => row['latency_sec'],
            'explanation' => row['explanation'] && JSON.parse(row['explanation'])
          }
        }
      end
    end

    def attempts
      normalized = rows(<<~SQL).map do |row|
        SELECT a.*, p.payment_system AS provider
        FROM routing_attempts a
        LEFT JOIN providers p ON p.payment_system_id = a.payment_system_id
        ORDER BY a.operation_id, a.attempt_number
      SQL
        {
          'operation_id' => row['operation_id'],
          'provider' => row['provider'],
          'decision' => row['decision'],
          'reason' => row['reason'],
          'attempt_number' => row['attempt_number'],
          'details' => row['details'] && JSON.parse(row['details']),
          'dispatched_at' => row['dispatched_at']
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
        'skip_unknown_provider' => first_value(<<~SQL)
          SELECT COUNT(*) FROM provider_skip_reasons s
          LEFT JOIN providers p ON p.payment_system_id = s.payment_system_id
          WHERE s.payment_system_id IS NOT NULL AND p.payment_system_id IS NULL
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

  class CanonicalReportDetails < Analyzer
    AMOUNT_BANDS = [
      ['0_1000', 0, 1000], ['1000_10000', 1000, 10_000],
      ['10000_50000', 10_000, 50_000], ['50000_100000', 50_000, 100_000],
      ['100000_plus', 100_000, nil]
    ].freeze
    FAILURE_REASONS = %w[provider_timeout provider_rejected provider_expired payout_failed provider_unavailable].freeze
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
        'attempt_cascades' => cascades,
        'segments' => segments,
        'period_comparison' => period_comparison,
        'skip_reason_sources' => skip_reason_sources,
        'routing_explanations' => @decisions.to_h { |row| [row['operation_id'], row['explanation'] && JSON.parse(row['explanation'])] },
        'freshness' => freshness
      }
    end

    private

    def routing_coverage(cascades)
      queue_ids = @pending_operations.map { |row| row['operation_id'] }.uniq
      decision_ids = @decisions_by_id.keys
      population = (queue_ids | decision_ids).length
      {
        'definition' => 'Выборка: уникальные идентификаторы операций из объединения operations_queue и routing_decisions. Операции, присутствующие только в истории, исключены; awaiting_decision отличается от показателя pending_operations.',
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
          'attempt_count' => 'Шаги оценки, записанные в журнале, включая пропущенных провайдеров; это не количество HTTP-запросов. Записи с нарушенными связями и искусственно добавленные справочные пропуски исключены.',
          'first_choice' => 'Ровно один выбранный провайдер, совпадающий с итоговым выбором в упорядоченном журнале с непрерывной нумерацией, без явных признаков перехода на резервный маршрут или сбоя. Пропуски из-за статических ограничений доступности не считаются сбоями отправки.',
          'fallback' => 'Итоговый выбор spacepayments, явная причина перехода на резервный маршрут, несколько выбранных провайдеров или зарегистрированный сбой до итогового выбора. Классификация основана на сохранённых журналах, полнота которых не проверена.',
          'failure_reasons' => FAILURE_REASONS,
          'explicit_fallback_reasons' => FALLBACK_REASONS,
          'success' => 'Успех определяется условием simulated_result = approved; результат платежа для каждой попытки и подтверждённые сведения о реальном или смоделированном происхождении данных не сохраняются.',
          'first_attempt_success_pct' => 'Количество одобренных операций с первым выбранным провайдером / количество всех классифицированных операций.',
          'cohort_approval_pct' => 'Количество одобренных операций / количество операций в соответствующей группе первого выбора или резервного маршрута.'
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
        'definition' => 'Та же выборка без дубликатов, что и для total_operations; решения имеют приоритет над историей. Доля одобрений рассчитывается от всех операций сегмента. Доли провайдеров рассчитываются внутри каждого сегмента. Суммы указаны в единицах базы данных; некорректные суммы и времена обработки исключаются из суммирования и статистики, количество некорректных сумм учитывается отдельно.',
        'window' => observation_window(@records),
        'amount_band_boundaries' => AMOUNT_BANDS.to_h { |name, lower, upper| [name, { 'min_inclusive' => lower, 'max_exclusive' => upper }] },
        'by_bank' => @records.group_by { |row| row['bank'].to_s.strip.empty? ? 'unknown' : row['bank'] }.sort.to_h.transform_values { |group| cohort_summary(group) },
        'by_amount' => by_amount.transform_values { |group| cohort_summary(group) }
      }
    end

    # Normalize explicit offsets to UTC
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
        'definition' => 'Последний день с наблюдениями до generated_at по UTC сравнивается с непосредственно предыдущим днём. Для завершённых дней используется интервал [00:00, 00:00 следующего дня); для текущего дня — [00:00, generated_at) и такой же по длительности интервал вчера. Замена предыдущего дня более ранним несмежным днём не выполняется.',
        'caveats' => ['Охват и полнота источников не фиксируются; отсутствие наблюдений не доказывает отсутствие активности.', 'Используются текущие сохранённые статусы с приоритетом решений над историей, а не восстановленные результаты на прошлый момент времени.'],
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
        'definition' => 'Подсчёт ведётся по уникальным сочетаниям операции, провайдера и причины. Показатели отдельных источников пересекаются и не должны суммироваться. Только routing_attempts является журналом фактических шагов маршрутизации; в provider_skip_reasons нет надёжного признака, отличающего фактические данные от справочных.',
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
        'definition' => 'Давность рассчитывается по сохранённому времени событий или справочных записей, а не по времени загрузки данных. Отрицательная давность означает временные метки из будущего. Даты без часового пояса интерпретируются как UTC. Нормативы актуальности и отметка последней загрузки данных отсутствуют.',
        'sources' => {
          'operations_history' => source_freshness(@history_rows),
          'operations_queue' => source_freshness(@pending_operations),
          'routing_decisions' => source_freshness(@decisions),
          'routing_attempts' => source_freshness(@details[:attempts]),
          'provider_skip_reasons' => source_freshness(@details[:stored_skips]),
          'providers' => { 'as_of' => nil, 'reason' => 'Время полного снимка состояния, целевых значений и лимитов не сохраняется.' }
        },
        'provider_metric_windows' => @providers.to_h do |provider|
          time = timestamp(provider['stats_calculated_at'])
          seconds = valid_amount(provider['stats_window_sec'])
          seconds = nil if seconds&.zero?
          [provider['payment_system'], {
            'analysis_from_exclusive' => time && seconds ? (time - seconds).iso8601(6) : nil,
            'analysis_to_inclusive' => time&.iso8601(6),
            'analysis_window_mode' => time ? (seconds ? 'rolling' : 'all_time') : nil,
            'minute_from_exclusive' => time ? (time - 60).iso8601(6) : nil,
            'minute_to_inclusive' => time&.iso8601(6), 'window_sec' => seconds,
            'conversion_24h_from_exclusive' => time ? (time - 86_400).iso8601(6) : nil,
            'last_calculation_age_sec' => time ? Utils.clean_number(@generated_at - time) : nil
          }]
        end,
        'blocks' => {
          'distribution_status_latency_segments' => { 'source' => 'operations_history и routing_decisions; при совпадении operation_id решение имеет приоритет', 'window' => observation_window(@records), 'outcome_provenance' => 'Статус из истории и simulated_result из решений; сведения о реальном или демонстрационном происхождении данных не сохраняются.' },
          'pending_queue' => { 'source' => 'operations_queue без идентификаторов, присутствующих в истории или решениях', 'window' => observation_window(unprocessed_pending_operations(latest_routing_events)) },
          'routing_coverage_cascades' => { 'source' => 'Очередь, исходные решения и исходные попытки; все сохранённые строки', 'decision_window' => observation_window(@decisions) },
          'skip_reasons' => { 'source' => 'См. skip_reason_sources; существующий показатель skip_reasons остаётся объединением этих источников без дубликатов.', 'window' => observation_window(@details[:stored_skips] + @details[:attempts].select { |row| row['decision'] == 'skipped' }) },
          'provider_state_utilization_recommendations' => { 'source' => 'Текущие сохранённые поля провайдеров; актуальность снимка неизвестна. Для пересчитанных метрик выше указаны отдельные временные окна.', 'as_of' => nil, 'recommendation_period' => period_label(latest_day_records(@records)) },
          'period_comparison' => { 'source' => 'Та же выборка операций без дубликатов; временные окна по UTC явно указаны в period_comparison.' }
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
        analyzer = Analyzer.new(**inputs)
        result = analyzer.report(generated_at: generated_at)
        result['skip_reasons'] = @source.skip_reason_counts
        providers = inputs.fetch(:provider_data).fetch('providers')
        providers.each do |provider|
          # Keep the legacy minute_stats key; persisted metrics have a configurable window.
          stats = provider.select { |key, _| CanonicalDatabaseSource::PROVIDER_STATS_COLUMNS.include?(key) }
          next if stats.empty?

          result['provider_state'].fetch(provider.fetch('payment_system'))['minute_stats'] = stats
        end
        result['source']['definitions'] = {
          'provider_snapshot' => 'Время полного снимка состояния провайдеров неизвестно; stats_calculated_at указывает время только для пересчитанных метрик.',
          'minute_stats' => 'Существующий ключ для сохранённых метрик провайдера. Окно анализа заканчивается в stats_calculated_at; stats_window_sec = null означает всю историю, иначе используется скользящее окно в секундах. requests_last_minute всегда использует 60 секунд; conversion_24h — 24 часа. При формировании этого отчёта метрики не пересчитываются.',
          'in_progress' => 'Обновление статистики провайдеров не меняет сохранённые in_progress_count/amount; это поля снимка текущей нагрузки провайдера.',
          'skip_reasons' => 'Уникальные сочетания операции, провайдера и причины из routing_attempts и provider_skip_reasons; последний источник может содержать импортированные справочные ожидания.'
        }
        details = @source.detail_inputs
        result.merge!(CanonicalReportDetails.new(**inputs, details: details).sections(generated_at: generated_at))
        result['recommendations'] = analyzer.recommendations_for(result, generated_at: generated_at, details: details)
        result
      end
    end

    def close
      @source.close
    end
  end
end
