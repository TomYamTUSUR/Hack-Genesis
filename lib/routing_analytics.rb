# frozen_string_literal: true

require 'csv'
require 'date'
require 'fileutils'
require 'json'
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
        data = parse_json(path)
        data.is_a?(Array) ? data : [data]
      end

      private

      def parse_json(path)
        JSON.parse(File.read(path, encoding: 'UTF-8'))
      rescue JSON::ParserError => e
        raise Error, "#{path}: malformed JSON: #{e.message}"
      end
    end
  end

  # Append-only audit journal. Every line is an independent JSON event so a
  # partially written final line cannot corrupt the preceding operation log.
  class OperationJournal
    REDACTED_FIELDS = %w[phone card_number pan cvv].freeze

    attr_reader :path

    def initialize(path, protected_roots: [])
      @path = path
      @protected_roots = protected_roots
    end

    def append(operation:, decision:, logged_at: Time.now)
      PathGuard.ensure_writable!(path, @protected_roots)
      validate_pair!(operation, decision)
      event = {
        'logged_at' => logged_at.iso8601,
        'event' => 'routing_operation',
        'operation_id' => operation['operation_id'],
        'operation' => sanitize(operation),
        'routing_decision' => Utils.deep_copy(decision)
      }

      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
        begin
          file.flock(File::LOCK_EX)
          file.write(JSON.generate(event))
          file.write("\n")
          file.flush
          file.fsync
        ensure
          file.flock(File::LOCK_UN)
        end
      end
      event
    end

    def read_all
      return [] unless File.exist?(path)

      events = []
      File.foreach(path, encoding: 'UTF-8').with_index(1) do |line, line_number|
        next if line.strip.empty?

        begin
          event = JSON.parse(line)
          unless event.is_a?(Hash) && event['operation'].is_a?(Hash) && event['routing_decision'].is_a?(Hash)
            raise Error, "#{path}: invalid operation journal event on line #{line_number}"
          end
          events << event
        rescue JSON::ParserError => e
          raise Error, "#{path}: malformed JSON on line #{line_number}: #{e.message}"
        end
      end
      events
    end

    private

    def validate_pair!(operation, decision)
      unless operation.is_a?(Hash) && operation['operation_id']
        raise Error, 'operation must contain operation_id'
      end
      unless decision.is_a?(Hash) && decision['operation_id']
        raise Error, 'routing decision must contain operation_id'
      end
      unless operation['operation_id'] == decision['operation_id']
        raise Error, "operation_id mismatch: #{operation['operation_id']} != #{decision['operation_id']}"
      end
      raise Error, 'routing decision must contain selected_provider' unless decision['selected_provider']
      raise Error, 'routing decision attempts must be an array' unless decision['attempts'].is_a?(Array)
    end

    def sanitize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), copy|
          copy[key] = if REDACTED_FIELDS.include?(key.to_s.downcase)
                        '[REDACTED]'
                      else
                        sanitize(nested)
                      end
        end
      when Array
        value.map { |item| sanitize(item) }
      else
        value
      end
    end
  end

  class Analyzer
    BASE_STATUSES = %w[approved rejected expired].freeze

    def initialize(provider_data:, history_rows:, journal_events: [], pending_operations: [])
      @provider_data = provider_data
      @providers = provider_data.fetch('providers')
      @history_rows = history_rows
      @journal_events = journal_events
      @pending_operations = pending_operations
      @provider_by_name = @providers.to_h { |provider| [provider['payment_system'], provider] }
    end

    def report(generated_at: Time.now)
      latest_events = latest_journal_events
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
        'source' => 'operation_journal'
      }
    end

    # Journal is an audit log and can contain replays. Analytics uses the most
    # recently appended event for each operation_id to avoid double counting.
    def latest_journal_events
      latest = {}
      @journal_events.each do |event|
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
      unique_journal_ids = @journal_events.filter_map do |event|
        event['operation_id'] || event.dig('operation', 'operation_id')
      end.uniq.length
      history_ids = @history_rows.map { |row| row['operation_id'] }
      journal_ids = latest_events.filter_map do |event|
        event['operation_id'] || event.dig('operation', 'operation_id')
      end
      overlap = (history_ids & journal_ids).length
      invalid_timestamps = records.count { |record| Utils.parse_time(record['created_at']).nil? }
      invalid_amounts = records.count { |record| record['amount'].nil? || record['amount'].negative? }
      unknown_providers = records.count do |record|
        record['payment_system'].nil? || !@provider_by_name.key?(record['payment_system'])
      end
      unknown_statuses = records.count { |record| !BASE_STATUSES.include?(record['status']) }
      duplicate_history_ids = history_ids.length - history_ids.compact.uniq.length
      snapshot_time = Utils.parse_time(@provider_data['snapshot_at'])
      snapshot_after_history = snapshot_time && history_times.any? && snapshot_time.to_date > history_times.max.to_date

      warnings = []
      warnings << "operations_history не отсортирован хронологически (обнаружено #{descents} переходов назад)" if descents.positive?
      if bank_mismatches.positive?
        warnings << "#{bank_mismatches} исторических назначений не соответствуют текущему снимку банков провайдеров; история используется для аналитики, а не для определения текущей доступности"
      end
      warnings << 'card_brand отсутствует у всех анализируемых операций' if records.any? && blank_card_brand == records.length
      warnings << 'у провайдеров не задан requests_per_minute_limit; аналитика по ограничениям частоты запросов недоступна' if @providers.none? { |provider| provider.key?('requests_per_minute_limit') }
      warnings << 'у провайдеров не задан volume_share_pct; отклонения от целевого распределения объёма недоступны' if @providers.none? { |provider| provider.key?('volume_share_pct') }
      warnings << "#{overlap} операций из журнала заменяют строки истории с тем же ID при расчёте агрегатов" if overlap.positive?
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
        'journal_events' => @journal_events.length,
        'journal_unique_operations' => unique_journal_ids,
        'journal_replayed_events' => @journal_events.length - unique_journal_ids,
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
