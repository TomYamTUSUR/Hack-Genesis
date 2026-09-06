# frozen_string_literal: true

require 'date'
require 'fileutils'
require 'json'
require 'sqlite3'
require 'time'
require_relative '../db/database'

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

  # provider/history file loading lives in PaymentRouting::Importers (Sequel-based,
  # see lib/payment_routing/importers) - this Loader only handles the JSON
  # inputs specific to the analytics/logging CLIs (bin/log_operations.rb).
  class Loader
    class << self
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
      eligible_providers operations_history operations_queue provider_skip_reasons
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

    # snapshot_at/gateway/merchant have no columns in the canonical schema (see
    # CanonicalDatabaseSource#provider_data) - kept nil here too so both
    # adapters produce the same Analyzer input shape from the same schema.
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
      attempts = rows(<<~SQL).group_by { |row| row['operation_id'] }
        SELECT a.*, p.payment_system AS provider
        FROM routing_attempts a
        LEFT JOIN providers p ON p.payment_system_id = a.payment_system_id
        ORDER BY a.operation_id, a.attempt_number
      SQL

      rows(<<~SQL).map do |row|
        SELECT d.*, d.created_at AS decision_created_at,
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
                'reason' => attempt['reason'],
                'details' => attempt['details'] && JSON.parse(attempt['details']),
                'dispatched_at' => attempt['dispatched_at']
              }
            end,
            'simulated_result' => row['simulated_result'],
            'latency_sec' => row['latency_sec'],
            'explanation' => row['explanation'] && JSON.parse(row['explanation'])
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

  # Writes routing results into an already-seeded database (see
  # PaymentRouting::Importers for seeding providers/history/queue from data/*).
  class DatabaseWriter < DatabaseBase
    def initialize(path, protected_roots: [], db: nil)
      @path = File.expand_path(path)
      PathGuard.ensure_writable!(@path, protected_roots)
      raise Error, "database does not exist: #{@path}" unless db || File.file?(@path)

      @owns_db = db.nil?
      @db = db || PaymentRouting::Db.connect(@path)
      validate_schema!
      PaymentRouting::Db.upgrade_schema!(@db)
    rescue Sequel::DatabaseError => e
      close
      raise Error, "unable to open database #{@path}: #{e.message}"
    end

    def close
      @db&.disconnect if @owns_db
    end

    # Passing the Router's Sequel connection joins its transaction, so decisions,
    # history and provider state commit or roll back together.
    def log_operations(operations:, decisions:, logged_at: Time.now)
      validate_pairs!(operations, decisions)
      decisions_by_id = decisions.to_h { |decision| [decision['operation_id'], decision] }
      logged_at = logged_at.iso8601(6)

      @db.transaction do
        operations.each do |operation|
          decision = decisions_by_id.fetch(operation['operation_id'])
          operation_id = required!(operation, 'operation_id')
          provider_id = provider_id!(decision['selected_provider'])
          queued = @db[:operations_queue].where(operation_id: operation_id).first || {}
          created_at = operation['created_at'] || queued[:created_at] || logged_at
          created_at = created_at.iso8601(6) if created_at.respond_to?(:iso8601)
          status = decision['simulated_result'] || 'unknown'

          upsert(:operations_history, {
            operation_id: operation_id, created_at: created_at,
            amount: required!(operation, 'amount'), bank: required!(operation, 'bank'),
            card_brand: operation.key?('card_brand') ? operation['card_brand'] : queued[:card_brand],
            payment_system_id: provider_id, status: status, latency_sec: decision['latency_sec']
          }, [:operation_id])
          upsert(:routing_decisions, {
            operation_id: operation_id, selected_payment_system_id: provider_id,
            simulated_result: status, latency_sec: decision['latency_sec'], created_at: logged_at,
            explanation: decision['explanation'] && JSON.generate(decision['explanation'])
          }, [:operation_id])

          %i[routing_attempts eligible_providers provider_skip_reasons].each do |table|
            @db[table].where(operation_id: operation_id).delete
          end
          decision['attempts'].each_with_index do |attempt, index|
            attempt_provider_id = provider_id!(attempt['provider'])
            @db[:routing_attempts].insert(
              operation_id: operation_id, payment_system_id: attempt_provider_id,
              attempt_number: index + 1, decision: attempt['decision'], reason: attempt['reason'],
              details: attempt['details'] && JSON.generate(attempt['details']),
              dispatched_at: attempt['dispatched_at'], created_at: logged_at
            )
            store_skip(operation_id, attempt_provider_id, attempt['reason'] || 'unknown', logged_at) if attempt['decision'] == 'skipped'
          end
          # Legacy JSON without a filter trace has unknown eligibility. Dispatch
          # outcomes must not manufacture results of checks that were not logged.
          (decision.dig('explanation', 'eligibility') || []).each do |check|
            id = provider_id!(check.fetch('provider'))
            @db[:eligible_providers].insert(
              operation_id: operation_id, payment_system_id: id,
              is_eligible: check.fetch('is_eligible'), checked_at: logged_at
            )
            check.fetch('reasons', []).each { |reason| store_skip(operation_id, id, reason, logged_at) }
          end
          # Queue rows remain for foreign keys; OperationQueueLoader excludes
          # IDs with history or decisions before dispatching them again.
        end
      end
      operations.length
    rescue Sequel::DatabaseError => e
      raise Error, "operation logging failed: #{e.message}"
    end

    private

    def rows(sql, bindings = [])
      @db.fetch(sql, *bindings).all.map { |row| row.transform_keys(&:to_s) }
    end

    def first_value(sql, bindings = [])
      @db.fetch(sql, *bindings).single_value
    end

    def store_skip(operation_id, provider_id, reason, logged_at)
      @db[:provider_skip_reasons].insert_conflict.insert(
        operation_id: operation_id, payment_system_id: provider_id, reason: reason, created_at: logged_at
      )
    end

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
      id = @db[:providers].where(payment_system: payment_system).get(:payment_system_id)
      raise Error, "unknown provider: #{payment_system.inspect}" unless id

      id
    end

    def required!(object, key)
      value = object[key]
      raise Error, "missing required field: #{key}" if value.nil? || value.to_s.empty?

      value
    end

    def upsert(table, values, conflict_columns)
      updates = values.reject { |key, _| conflict_columns.include?(key) }
      @db[table].insert_conflict(target: conflict_columns, update: updates).insert(values)
    end
  end

  # Recommendations use the latest observed day; routing coverage uses the retained log.
  # Missing evidence never counts as a zero score, zero capacity, or a stale snapshot.
  class Recommendations
    # Unspecified business thresholds are explicit defaults. Approval comparisons
    # require 10 operations per cohort and a 15 percentage-point gap. A stable
    # amount-band leader must beat every observed peer on two adjacent days.
    # Frequent skips use distinct evaluated operations; dominance uses distinct skips.
    # Score gaps are relative to the larger absolute score, not to score weights.
    THRESHOLDS = {
      min_operations: 10, share_gap_pp: 5, approval_gap_pp: 15, high_approval_pct: 90,
      low_traffic_pct: 5, daily_utilization_pct: 90, workload_utilization_pct: 80,
      expired_pct: 20, p95_sec: 60, tail_ratio: 3, latency_gap_sec: 10,
      status_latency_samples: 5, expired_latency_ratio: 2, min_requisites: 3,
      min_skips: 5, frequent_skip_pct: 20, dominant_skip_pct: 50,
      max_eligible_providers: 1, limited_eligibility_pct: 20,
      close_score_gap_pct: 5, strong_score_gap_pct: 25,
      fallback_rate_pct: 20, high_fallback_approval_pct: 80, low_fallback_approval_pct: 50,
      statistics_max_age_sec: 300, snapshot_max_age_sec: 3600
    }.freeze
    AMOUNT_BANDS = [
      ['от 0 до 1 000', 0, 1000], ['от 1 000 до 10 000', 1000, 10_000],
      ['от 10 000 до 50 000', 10_000, 50_000], ['от 50 000 до 100 000', 50_000, 100_000],
      ['от 100 000', 100_000, nil]
    ].freeze
    SKIP_LABELS = {
      'bank_not_in_list' => 'банк не входит в список доступных',
      'amount_exceeds_limit' => 'сумма превышает допустимый предел',
      'daily_amount_limit_exceeded' => 'дневной лимит суммы исчерпан',
      'provider_timeout' => 'превышено время ожидания провайдера',
      'provider_rejected' => 'провайдер отклонил операцию',
      'provider_expired' => 'истёк срок обработки операции',
      'provider_unavailable' => 'провайдер недоступен',
      'unknown' => 'причина не указана'
    }.freeze

    def initialize(providers:, records:, all_records:, report:, generated_at:, details: {}, snapshot_at: nil)
      @providers = providers
      @by_name = providers.to_h { |provider| [provider['payment_system'], provider] }
      @by_id = providers.to_h { |provider| [provider['payment_system_id'], provider['payment_system']] }
      @generated_at = generated_at.getutc
      @report = report
      @details = details
      @snapshot_at = time(snapshot_at)
      @scope_ids = records.to_h { |row| [row['operation_id'], true] }
      @records = records.select { |row| valid_record?(row) }
      @all_records = all_records.select { |row| valid_record?(row) }
      @groups = @records.group_by { |row| row['payment_system'] }
      @skip_groups = @details.fetch(:attempts, [])
        .select { |row| @scope_ids.key?(row['operation_id']) && @by_id.key?(row['payment_system_id']) }
        .group_by { |row| row['payment_system_id'] }
      @result = []
    end

    def call
      quality_recommendations
      if @records.empty?
        @result << 'Недостаточно операций для рекомендаций; накопить журнал новых решений.'
      end
      @providers.each { |provider| provider_recommendations(provider) }
      skip_recommendations
      eligibility_recommendations
      segment_recommendations unless @records.empty?
      score_recommendations
      routing_recommendations
      @result.uniq
    end

    private

    def number(value)
      parsed = Utils.number(value)
      parsed if parsed&.finite?
    end

    def time(value)
      return nil if value.nil? || value.to_s.strip.empty?

      value = value.to_s.strip
      value += ' UTC' unless value.match?(/(?:Z|UTC|[+-]\d{2}:?\d{2})\z/i)
      Time.parse(value).getutc
    rescue ArgumentError
      nil
    end

    def valid_record?(row)
      amount = number(row['amount'])
      at = time(row['created_at'])
      @by_name.key?(row['payment_system']) && amount && amount >= 0 && at && at <= @generated_at
    end

    def enough?(rows)
      rows.length >= THRESHOLDS[:min_operations]
    end

    def approval(rows)
      Utils.percentage(rows.count { |row| row['status'] == 'approved' }, rows.length)
    end

    def latency_values(rows)
      rows.filter_map { |row| value = number(row['latency_sec']); value if value && value >= 0 }
    end

    def utilization(provider, used_key, limit_key)
      used = number(provider[used_key])
      limit = number(provider[limit_key])
      Utils.percentage(used, limit) if used && used >= 0 && limit&.positive?
    end

    def stale?(provider)
      calculated_at = time(provider['stats_calculated_at'])
      (calculated_at && @generated_at - calculated_at > THRESHOLDS[:statistics_max_age_sec]) ||
        (@snapshot_at && @generated_at - @snapshot_at > THRESHOLDS[:snapshot_max_age_sec])
    end

    def constrained?(provider)
      daily = utilization(provider, 'daily_approved_amount', 'daily_amount_limit')
      count = utilization(provider, 'in_progress_count', 'in_progress_count_limit')
      amount = utilization(provider, 'in_progress_amount', 'in_progress_amount_limit')
      requisites = number(provider['available_requisites'])
      status = provider['status'].to_s.strip.downcase
      (!status.empty? && status != 'active') || stale?(provider) ||
        frequent_blocking_skips?(provider) ||
        (daily && daily >= THRESHOLDS[:daily_utilization_pct]) ||
        [count, amount].compact.any? { |value| value >= THRESHOLDS[:workload_utilization_pct] } ||
        (requisites && requisites < THRESHOLDS[:min_requisites])
    end

    def degraded?(name)
      rows = @groups.fetch(name, [])
      peers = @records.reject { |row| row['payment_system'] == name }
      latencies = latency_values(rows)
      (enough?(rows) && Utils.percentage(rows.count { |row| row['status'] == 'expired' }, rows.length) >= THRESHOLDS[:expired_pct]) ||
        (enough?(rows) && enough?(peers) && approval(peers) - approval(rows) >= THRESHOLDS[:approval_gap_pp]) ||
        (enough?(latencies) && Utils.percentile(latencies, 0.95) > THRESHOLDS[:p95_sec])
    end

    def can_increase?(provider)
      !@invalid_data && !constrained?(provider) && !degraded?(provider['payment_system'])
    end

    def frequent_blocking_skips?(provider)
      rows = @skip_groups.fetch(provider['payment_system_id'], [])
      evaluated = rows.map { |row| row['operation_id'] }.uniq.length
      return false if evaluated < THRESHOLDS[:min_operations]

      %w[bank_not_in_list daily_amount_limit_exceeded].any? do |reason|
        count = rows.select { |row| row['decision'] == 'skipped' && row['reason'] == reason }
          .map { |row| row['operation_id'] }.uniq.length
        count >= THRESHOLDS[:min_skips] && Utils.percentage(count, evaluated) >= THRESHOLDS[:frequent_skip_pct]
      end
    end

    def quality_recommendations
      quality = @report.fetch('data_quality', {})
      @invalid_data = %w[unknown_provider_count invalid_amount_count invalid_timestamp_count].any? { |key| quality[key].to_i.positive? }
      @invalid_data ||= @report.dig('routing_coverage', 'unknown_selected_provider').to_i.positive?
      @invalid_data ||= quality.fetch('database_orphans', {}).values.any? { |count| count.to_i.positive? }
      if @invalid_data
        @result << 'Есть неизвестные провайдеры, некорректные суммы, даты или нарушенные связи; не использовать затронутую выборку для автоматической оптимизации до исправления данных.'
      end
    end

    def provider_recommendations(provider)
      name = provider['payment_system']
      rows = @groups.fetch(name, [])
      state_recommendations(provider)
      return if @records.empty?

      count_share = Utils.percentage(rows.length, @records.length)
      volume_share = Utils.percentage(rows.sum { |row| number(row['amount']) }, @records.sum { |row| number(row['amount']) })
      target = number(provider['traffic_percentage'])
      volume_target = number(provider['volume_share_pct'])
      gap = target&.positive? ? count_share - target : nil
      volume_gap = volume_target && volume_share ? volume_share - volume_target : nil
      daily = utilization(provider, 'daily_approved_amount', 'daily_amount_limit')
      increase = can_increase?(provider)

      if daily && daily >= THRESHOLDS[:daily_utilization_pct] && gap && gap <= -THRESHOLDS[:share_gap_pp]
        @result << "#{name}: дневной лимит использован на #{daily}%, доля количества ниже цели на #{Utils.clean_number(-gap)} п.п.; увеличить доступную ёмкость или снизить целевую долю."
      elsif daily && daily >= THRESHOLDS[:daily_utilization_pct]
        @result << "#{name}: дневной лимит использован на #{daily}%; временно снизить приоритет или вес провайдера до обновления лимита."
      elsif gap && gap <= -THRESHOLDS[:share_gap_pp] && increase
        @result << "#{name}: доля количества ниже цели на #{Utils.clean_number(-gap)} п.п.; повысить вес распределения по количеству среди допустимых провайдеров."
      elsif gap && gap >= THRESHOLDS[:share_gap_pp]
        @result << "#{name}: доля количества выше цели на #{Utils.clean_number(gap)} п.п.; снизить вес распределения по количеству среди допустимых провайдеров."
      end
      if volume_gap && volume_gap <= -THRESHOLDS[:share_gap_pp] && increase
        @result << "#{name}: доля суммы ниже цели на #{Utils.clean_number(-volume_gap)} п.п.; повысить вес распределения по объёму для провайдера."
      elsif volume_gap && volume_gap >= THRESHOLDS[:share_gap_pp]
        @result << "#{name}: доля суммы выше цели на #{Utils.clean_number(volume_gap)} п.п.; снизить вес распределения по объёму."
      end
      if gap && gap.abs < THRESHOLDS[:share_gap_pp] && volume_gap && volume_gap.abs >= THRESHOLDS[:share_gap_pp]
        @result << "#{name}: доля количества соответствует цели, но доля суммы отклонена на #{Utils.clean_number(volume_gap)} п.п.; проверить распределение по суммам: распределение по количеству не обеспечивает целевой объём."
      end
      performance_recommendations(provider, rows, count_share, gap, increase)
    end

    def state_recommendations(provider)
      name = provider['payment_system']
      count = utilization(provider, 'in_progress_count', 'in_progress_count_limit')
      amount = utilization(provider, 'in_progress_amount', 'in_progress_amount_limit')
      if count && count >= THRESHOLDS[:workload_utilization_pct]
        @result << "#{name}: лимит количества операций в обработке использован на #{count}%; снизить входящий поток по количеству до освобождения доступной ёмкости."
      end
      if amount && amount >= THRESHOLDS[:workload_utilization_pct]
        @result << "#{name}: лимит суммы операций в обработке использован на #{amount}%; ограничить крупные операции либо перераспределить объём на других провайдеров."
      end
      requisites = number(provider['available_requisites'])
      if requisites && requisites < THRESHOLDS[:min_requisites]
        @result << "#{name}: мало доступных реквизитов (#{Utils.clean_number(requisites)}); не увеличивать трафик до восстановления доступных реквизитов."
      end
      status = provider['status'].to_s.strip.downcase
      if !status.empty? && status != 'active'
        @result << "#{name}: провайдер неактивен; исключить из основного пула и использовать только после восстановления состояния."
      end
      if stale?(provider)
        @result << "#{name}: данные провайдера устарели; не изменять веса автоматически, сначала обновить снимок состояния и статистику провайдера."
      end
    end

    def performance_recommendations(provider, rows, count_share, gap, increase)
      name = provider['payment_system']
      if enough?(rows)
        expired = Utils.percentage(rows.count { |row| row['status'] == 'expired' }, rows.length)
        if expired >= THRESHOLDS[:expired_pct]
          @result << "#{name}: доля операций с истёкшим сроком составляет #{expired}%; проверить время ожидания и обработки до увеличения трафика."
        end
        peers = @records.reject { |row| row['payment_system'] == name }
        if enough?(peers) && approval(peers) - approval(rows) >= THRESHOLDS[:approval_gap_pp]
          @result << "#{name}: успешность #{approval(rows)}% существенно ниже остальных провайдеров (#{approval(peers)}%); снизить вес показателя успешности или общий приоритет провайдера до восстановления успешности."
        end
        low_traffic = count_share < THRESHOLDS[:low_traffic_pct] || (gap && gap <= -THRESHOLDS[:share_gap_pp])
        if approval(rows) >= THRESHOLDS[:high_approval_pct] && low_traffic && increase && number(provider['traffic_percentage'])&.positive?
          @result << "#{name}: успешность высокая (#{approval(rows)}%), но трафика мало; рассмотреть увеличение веса провайдера, если ограничения и лимиты позволяют."
        end
      end
      latencies = latency_values(rows)
      if enough?(latencies)
        p95 = Utils.percentile(latencies, 0.95)
        p50 = Utils.median(latencies)
        if p95 > THRESHOLDS[:p95_sec]
          @result << "#{name}: 95-й перцентиль времени обработки составляет #{p95} с и превышает порог #{THRESHOLDS[:p95_sec]} с; ограничить новый трафик и проверить деградацию провайдера."
        end
        if p95 >= p50 * THRESHOLDS[:tail_ratio] && p95 - p50 >= THRESHOLDS[:latency_gap_sec]
          @result << "#{name}: 95-й перцентиль времени обработки (#{p95} с) значительно выше медианы (#{p50} с); наблюдается длинный хвост времени обработки, проверить нестабильные или зависшие операции."
        end
      end
      expired = latency_values(rows.select { |row| row['status'] == 'expired' })
      approved = latency_values(rows.select { |row| row['status'] == 'approved' })
      return unless [expired, approved].all? { |values| values.length >= THRESHOLDS[:status_latency_samples] }

      expired_avg = expired.sum / expired.length
      approved_avg = approved.sum / approved.length
      if expired_avg >= approved_avg * THRESHOLDS[:expired_latency_ratio] && expired_avg - approved_avg >= THRESHOLDS[:latency_gap_sec]
        @result << "#{name}: операции с истёкшим сроком обрабатываются значительно дольше одобренных; сократить время ожидания или раньше переключаться на резервный маршрут."
      end
    end

    def skip_recommendations
      @skip_groups.each do |id, rows|
        evaluated = rows.map { |row| row['operation_id'] }.uniq.length
        skips = rows.select { |row| row['decision'] == 'skipped' }
          .uniq { |row| [row['operation_id'], row['reason']] }
        counts = skips.map { |row| row['reason'] || 'unknown' }.tally
        name = @by_id[id]
        counts.sort.each do |reason, count|
          next if count < THRESHOLDS[:min_skips]

          label = SKIP_LABELS.fetch(reason) { "код причины «#{reason}»" }
          if Utils.percentage(count, skips.length) >= THRESHOLDS[:dominant_skip_pct]
            @result << "#{name}: среди пропусков доминирует причина «#{label}» (#{count}); скорректировать правила провайдера либо стратегию маршрутизации по этой причине."
          end
          next unless evaluated >= THRESHOLDS[:min_operations] && Utils.percentage(count, evaluated) >= THRESHOLDS[:frequent_skip_pct]

          advice = case reason
                   when 'bank_not_in_list'
                     'не увеличивать глобальную долю провайдера; учитывать доступность по банкам'
                   when 'amount_exceeds_limit'
                     'перенаправлять крупные операции к провайдерам с большим диапазоном сумм'
                   when 'daily_amount_limit_exceeded'
                     'уменьшить целевую долю либо увеличить дневной лимит; дальнейшее повышение веса бессмысленно'
                   end
          @result << "#{name}: частые пропуски по причине «#{label}» (#{count} из #{evaluated} операций); #{advice}." if advice
        end
      end
    end

    def eligibility_recommendations
      known_operations = (@details.fetch(:decisions, []).map { |row| row['operation_id'] } +
        @details.fetch(:queue, []).map { |row| row['operation_id'] }).to_h { |id| [id, true] }
      rows = @details.fetch(:eligibility, []).select { |row| known_operations.key?(row['operation_id']) }
      # Only operations with recorded checks form the denominator; absent checks are unknown.
      groups = rows.group_by { |row| row['operation_id'] }.reject do |id, checks|
        id.nil? || checks.any? { |row| !@by_id.key?(row['payment_system_id']) || ![true, false, 1, 0, '1', '0'].include?(row['is_eligible']) }
      end
      return unless groups.length >= THRESHOLDS[:min_operations]

      limited = groups.count do |_, checks|
        checks.select { |row| [true, 1, '1'].include?(row['is_eligible']) && @by_id.key?(row['payment_system_id']) }
          .map { |row| row['payment_system_id'] }.uniq.length <= THRESHOLDS[:max_eligible_providers]
      end
      share = Utils.percentage(limited, groups.length)
      if share >= THRESHOLDS[:limited_eligibility_pct]
        @result << "Для #{share}% операций с проверкой доступности имеется не более одного допустимого провайдера; высок риск отсутствия маршрута, расширить покрытие провайдеров и пересмотреть ограничения."
      end
    end

    def segment_recommendations
      @records.group_by { |row| row['bank'] }.each do |bank, rows|
        next if bank.to_s.strip.empty?

        compare_segment(rows) do |name, gap|
          if gap <= -THRESHOLDS[:approval_gap_pp]
            @result << "#{name}, банк «#{bank}»: успешность заметно ниже остальных провайдеров этого банка; снизить вес провайдера для данного банка."
          elsif gap >= THRESHOLDS[:approval_gap_pp] && can_increase?(@by_name.fetch(name))
            @result << "#{name}, банк «#{bank}»: успешность заметно выше остальных провайдеров этого банка при достаточной выборке; повысить предпочтение провайдера для данного банка."
          end
        end
      end
      latest_date = @records.map { |row| time(row['created_at']).to_date }.max
      previous = @all_records.select { |row| time(row['created_at']).to_date == latest_date - 1 }
      AMOUNT_BANDS.each do |label, lower, upper|
        in_band = ->(row) { amount = number(row['amount']); amount >= lower && (upper.nil? || amount < upper) }
        rows = @records.select(&in_band)
        prior = previous.select(&in_band)
        compare_segment(rows) do |name, gap|
          if gap <= -THRESHOLDS[:approval_gap_pp]
            @result << "#{name}, сумма #{label}: успешность заметно ниже остальных провайдеров; снизить приоритет для данного диапазона сумм."
          elsif gap >= THRESHOLDS[:approval_gap_pp] && best_in_segment?(name, rows) && best_in_segment?(name, prior) && can_increase?(@by_name.fetch(name))
            @result << "#{name}, сумма #{label}: провайдер лучший по успешности в двух соседних днях при достаточной выборке; повысить приоритет внутри данного диапазона."
          end
        end
      end
    end

    def compare_segment(rows)
      rows.group_by { |row| row['payment_system'] }.each do |name, own|
        peers = rows.reject { |row| row['payment_system'] == name }
        yield name, approval(own) - approval(peers) if enough?(own) && enough?(peers)
      end
    end

    def best_in_segment?(name, rows)
      groups = rows.group_by { |row| row['payment_system'] }
      own = groups.delete(name) || []
      enough?(own) && !groups.empty? && groups.values.all? do |peers|
        enough?(peers) && approval(own) - approval(peers) >= THRESHOLDS[:approval_gap_pp]
      end
    end

    # Supported saved rankings: arrays of provider/score entries or provider=>score maps.
    # Never compare weights, individual score components, or inferred current ratings.
    def score_recommendations
      counts = Hash.new(0)
      @details.fetch(:decisions, []).each do |decision|
        explanation = decision['explanation']
        explanation = JSON.parse(explanation) if explanation.is_a?(String)
        next unless explanation.is_a?(Hash)

        ranking = explanation['ranking'] || explanation['scores']
        ranking = ranking.map { |name, score| { 'provider' => name, 'score' => score } } if ranking.is_a?(Hash)
        next unless ranking.is_a?(Array)

        scores = ranking.filter_map do |entry|
          next unless entry.is_a?(Hash) && ![false, 0, '0'].include?(entry['is_eligible'])

          name = entry['provider'] || entry['payment_system'] || @by_id[entry['payment_system_id']]
          score = number(entry['score'] || entry['total_score'])
          [name, score] if @by_name.key?(name) && score
        end
        next unless scores.length >= 2 && scores.map(&:first).uniq.length == scores.length

        first, second = scores.sort_by { |_, score| -score }.first(2)
        scale = [first.last.abs, second.last.abs].max
        gap = scale.zero? ? 0 : 100.0 * (first.last - second.last) / scale
        if gap <= THRESHOLDS[:close_score_gap_pct]
          counts[:close] += 1
        elsif gap >= THRESHOLDS[:strong_score_gap_pct] && first.first == @by_id[decision['selected_payment_system_id']] && can_increase?(@by_name.fetch(first.first))
          counts[:strong] += 1
        end
      rescue JSON::ParserError
        next
      end
      if counts[:close].positive?
        @result << "Для #{counts[:close]} операций оценки двух лучших провайдеров почти одинаковы; решение имеет низкую уверенность, сильнее учитывать балансировку и целевую долю."
      end
      if counts[:strong].positive?
        @result << "Для #{counts[:strong]} операций оценка выбранного провайдера значительно выше второй; сохранить выбор, имеется сильное основание для маршрута."
      end
    end

    def routing_recommendations
      coverage = number(@report.dig('routing_coverage', 'decision_coverage_pct'))
      if coverage && coverage < 100
        @result << "Решения покрывают #{coverage}% операций; проверить необработанные операции и журнал решений."
      end
      cascades = @report.fetch('attempt_cascades', {})
      logs = number(cascades['attempt_log_coverage_pct'])
      if logs && logs < 100
        @result << "Журнал шагов покрывает #{logs}% решений; недостаточно данных для надёжного анализа резервных маршрутов и качества маршрутизации."
      end
      decisions = @report.dig('routing_coverage', 'with_decision').to_i
      rate = number(@report.dig('routing_coverage', 'fallback_share_of_decisions_pct'))
      if decisions >= THRESHOLDS[:min_operations] && rate && rate >= THRESHOLDS[:fallback_rate_pct]
        @result << "Доля резервных маршрутов высокая (#{rate}%); проверить качество первого выбора и причины отказов до переключения на резерв."
      end
      return unless cascades['fallback_operations'].to_i >= THRESHOLDS[:min_operations]

      approved = number(cascades['fallback_approval_pct'])
      if approved && approved >= THRESHOLDS[:high_fallback_approval_pct]
        @result << "Успешность резервных маршрутов высокая (#{approved}%); резерв эффективно восстанавливает операции, сохранить резервный маршрут."
      elsif approved && approved < THRESHOLDS[:low_fallback_approval_pct]
        @result << "Успешность резервных маршрутов низкая (#{approved}%); пересмотреть порядок резервных провайдеров."
      end
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

      result = {
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
        'recommendation_period' => period_label(recommendation_records)
      }
      result['recommendations'] = recommendations_for(result, generated_at: generated_at)
      result
    end

    def recommendations_for(report, generated_at:, details: {})
      records = combined_records(latest_routing_events)
      Recommendations.new(
        providers: @providers, records: latest_day_records(records), all_records: records,
        report: report, generated_at: generated_at, details: details,
        snapshot_at: @provider_data['snapshot_at']
      ).call
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
        'foreign_key_definitions' => @source_metadata['foreign_key_definitions']
      }
    end

    def current_bank_rule_mismatch?(record)
      provider = @provider_by_name[record['payment_system']]
      return false unless provider

      banks = provider['banks'] || []
      return false if banks.empty?

      provider['exclude_banks'] ? banks.include?(record['bank']) : !banks.include?(record['bank'])
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
