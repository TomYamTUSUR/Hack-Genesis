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
# Analysis window: all history through at by default, or (at - window_seconds, at].
# SQLite timestamps include UTC offsets. Each run replaces the provider snapshot.
# Per-minute request count/amount (all statuses) are report-only (see
# 'requests_last_minute' and periods.minute in the JSON) - they are NOT written
# to in_progress_count/in_progress_amount. Those columns mean concurrently
# in-flight requests elsewhere in this project (hard-constraint capacity,
# PaymentRouting::Rating load factor); a per-minute arrival count is a
# different thing and would silently corrupt that meaning if persisted there.
# Adds missing SHARE_COLUMNS. Writes requests_last_minute only if it already exists.
# Updates conversion_24h over the last 24 hours and avg_latency_sec over the analysis
# window (all known latencies, rounded to seconds). Missing observations produce NULL.
# Daily created-operation totals are report-only; there is no completion time to
# safely recalculate daily_approved_amount. Targets and limits are never updated.
# Usage: ruby bin/update_provider_minute_stats.rb [--window-seconds N|all] [--at ISO8601] [--dry-run]
class ProviderMinuteStats
  class Error < StandardError; end

  # Дополнительные поля результата: 12 показателей и время/длина окна.
  # Недостающие колонки создаются только при запуске с записью в базу.
  SHARE_COLUMNS = {
    'actual_count_share_pct' => 'REAL',
    'actual_volume_share_pct' => 'REAL',
    'approved_volume_share_pct' => 'REAL',
    'count_target_fulfillment_pct' => 'REAL',
    'volume_target_fulfillment_pct' => 'REAL',
    'count_share_gap_pp' => 'REAL',
    'volume_share_gap_pp' => 'REAL',
    'approval_rate_pct' => 'REAL',
    'rejection_rate_pct' => 'REAL',
    'expiration_rate_pct' => 'REAL',
    'approved_amount_pct' => 'REAL',
    'terminal_approval_rate_pct' => 'REAL',
    # The calculation reference time (window end), including for --at replays.
    'stats_calculated_at' => 'TEXT',
    'stats_window_sec' => 'INTEGER'
  }.freeze

  # database — существующая SQLite-база; at — конец окна (по умолчанию сейчас).
  # window_seconds — положительное число секунд; nil означает всю историю до at.
  # dry_run оставляет базу и её схему без изменений, но формирует полный отчёт.
  def initialize(database:, at: nil, dry_run: false, window_seconds: nil)
    unless window_seconds.nil? || (window_seconds.is_a?(Integer) && window_seconds.positive?)
      raise Error, 'window_seconds must be a positive integer or nil (all history)'
    end

    @path = File.expand_path(database)
    @at = at
    @dry_run = dry_run
    @window_seconds = window_seconds
  end

  # Один запуск: проверка данных, расчёт, необязательная запись и возврат Hash.
  def run
    raise Error, "Database does not exist: #{@path}" unless File.file?(@path)

    # READWRITE не создаёт отсутствующую базу; READONLY запрещает запись в dry-run.
    flags = @dry_run ? SQLite3::Constants::Open::READONLY : SQLite3::Constants::Open::READWRITE
    database = SQLite3::Database.new(@path, flags: flags)
    database.busy_timeout = 5000
    database.execute('PRAGMA foreign_keys = ON')
    result = nil
    # Расчёт и запись используют одну транзакцию. IMMEDIATE резервирует запись
    # заранее; ошибка откатывает и обновления провайдеров, и добавление колонок.
    database.transaction(@dry_run ? :deferred : :immediate) do
      at = (@at || Time.now).getutc
      result = build_report(database, at: at)
      columns = database.execute('PRAGMA table_info(providers)').map { |row| row['name'] }
      fields = %w[conversion_24h avg_latency_sec]
      missing = fields - columns
      raise Error, "providers: missing columns #{missing.join(', ')}" unless missing.empty?

      # Совместимость с базами, где счётчик запросов был добавлен отдельно.
      fields << 'requests_last_minute' if columns.include?('requests_last_minute')
      fields.concat(SHARE_COLUMNS.keys)
      columns_to_add = SHARE_COLUMNS.keys - columns
      unless @dry_run
        columns_to_add.each do |column|
          database.execute("ALTER TABLE providers ADD COLUMN #{column} #{SHARE_COLUMNS.fetch(column)}")
        end
        # Заменяем текущий снимок каждого провайдера, а не накапливаем значения.
        # Порядок привязанных значений совпадает с порядком колонок в SET.
        result.fetch('providers').each do |row|
          assignments = fields.map { |field| "#{field} = ?" }.join(', ')
          database.execute("UPDATE providers SET #{assignments} WHERE payment_system_id = ?",
                           row.values_at(*fields, 'payment_system_id'))
        end
      end
      # В dry-run показываем план записи: columns_to_add ещё не созданы.
      result['persistence'] = {
        'dry_run' => @dry_run, 'columns' => fields,
        'columns_to_add' => columns_to_add,
        'schema_changed' => !@dry_run && !columns_to_add.empty?
      }
    end
    result
  ensure
    # Освобождаем соединение и при успешном расчёте, и при исключении.
    database&.close
  end

  # Интерфейс для вызова из Ruby: возвращает только показатели провайдеров.
  # Переданное соединение не закрывается; данные и схема не изменяются.
  def calculate(database, at:)
    build_report(database, at: at).fetch('providers')
  end

  # Формирует полный отчёт без записи. Временные окна строятся по created_at,
  # статусы берутся из текущей истории, а не восстанавливаются на момент at.
  def build_report(database, at:)
    database.results_as_hash = true
    validate_source!(database)
    # Fail before publishing misleading zeroes for unparseable source dates.
    # Проверяем даты во всей истории: некорректная дата не должна незаметно
    # исключить операцию из выборки и привести к ложным нулевым показателям.
    invalid = database.get_first_value(<<~SQL)
      SELECT operation_id FROM operations_history
      WHERE created_at IS NULL OR julianday(created_at) IS NULL
      LIMIT 1
    SQL
    raise Error, "Invalid or missing operations_history.created_at: #{invalid}" if invalid

    # Загружаем объединение основного окна и вспомогательных периодов.
    # При расчёте за всё время нижней границы нет; будущие операции исключены.
    start_at = @window_seconds && (at - [@window_seconds, 86_400].max).getutc.iso8601(6)
    end_at = at.getutc.iso8601(6)
    invalid = database.get_first_value(<<~SQL, [start_at, start_at, end_at])
      SELECT h.operation_id FROM operations_history h
      LEFT JOIN providers p ON p.payment_system_id = h.payment_system_id
      WHERE (? IS NULL OR julianday(h.created_at) >= julianday(?))
        AND julianday(h.created_at) <= julianday(?)
        AND (p.payment_system_id IS NULL OR typeof(h.amount) NOT IN ('integer', 'real') OR h.amount < 0
             OR (h.latency_sec IS NOT NULL AND (typeof(h.latency_sec) NOT IN ('integer', 'real') OR h.latency_sec < 0)))
      LIMIT 1
    SQL
    raise Error, "Missing provider or invalid amount/latency for operation: #{invalid}" if invalid

    # Один раз загружаем общую выборку для всех периодов. julianday приводит
    # даты с разными UTC-сдвигами к сопоставимым числовым значениям.
    history = database.execute(<<~SQL, [start_at, start_at, end_at])
      SELECT operation_id, payment_system_id, amount, status, bank, latency_sec,
             julianday(created_at) AS created_jd
      FROM operations_history
      WHERE (? IS NULL OR julianday(created_at) >= julianday(?)) AND julianday(created_at) <= julianday(?)
      ORDER BY julianday(created_at), operation_id
    SQL
    providers = database.execute('SELECT * FROM providers ORDER BY payment_system_id')
    windows = period_windows(at.getutc)
    # Для каждого периода выбираем строки с учётом включённости его границ.
    cohorts = windows.to_h do |name, window|
      lower = database.get_first_value('SELECT julianday(?)', [window['start']])
      upper = database.get_first_value('SELECT julianday(?)', [window['end']])
      selected = history.select do |row|
        after_start = lower.nil? || (window['start_inclusive'] ? row['created_jd'] >= lower : row['created_jd'] > lower)
        after_start && row['created_jd'] <= upper
      end
      [name, selected]
    end
    # Общие итоги периода служат знаменателями долей отдельных провайдеров.
    totals = cohorts.transform_values { |rows| ProviderMinuteMetrics.summary(rows) }
    groups = cohorts.transform_values { |rows| rows.group_by { |row| row['payment_system_id'] } }
    # Обрабатываем всех провайдеров, включая неактивных и не имеющих операций.
    # Пустая выборка даёт нули для количества/суммы и nil для неопределимых метрик.
    rows = providers.map do |provider|
      id = provider.fetch('payment_system_id')
      metrics = groups.to_h do |name, grouped|
        [name, ProviderMinuteMetrics.shares(ProviderMinuteMetrics.summary(grouped.fetch(id, [])), totals.fetch(name))]
      end
      minute = metrics.fetch('minute')
      analysis = metrics.fetch('analysis')
      previous = metrics.fetch('previous_minute')
      day = metrics.fetch('last_24h')
      # Конверсия сохраняется как доля 0..1 за сутки; показатели основного окна
      # выражаются в процентах. Все статусы входят в знаменатель конверсии.
      conversion = day['count'].zero? ? nil : day.dig('statuses', 'approved', 'count').to_f / day['count']
      targets = ProviderMinuteMetrics.targets(provider, minute)
      targets['count_share_gap_pp'] = ProviderMinuteMetrics.target_gap(analysis['count_share_pct'], provider['traffic_percentage'])
      targets['amount_share_gap_pp'] = ProviderMinuteMetrics.target_gap(analysis['amount_share_pct'], provider['volume_share_pct'])
      # Выполнение цели = фактическая доля / целевая доля * 100.
      # Оно может превышать 100%; при отсутствующей или нулевой цели будет nil.
      targets['count_target_fulfillment_pct'] = ProviderMinuteMetrics.percentage(
        analysis['count_share_pct'], provider['traffic_percentage']
      )
      targets['volume_target_fulfillment_pct'] = ProviderMinuteMetrics.percentage(
        analysis['amount_share_pct'], provider['volume_share_pct']
      )
      {
        'payment_system_id' => id, 'payment_system' => provider.fetch('payment_system'),
        # Эти in_progress_* — только JSON-совместимость: минутный поток;
        # одноимённые поля providers скрипт не обновляет.
        'requests_last_minute' => minute['count'], 'in_progress_count' => minute['count'],
        'in_progress_amount' => minute['amount'], 'conversion_24h' => conversion,
        'avg_latency_sec' => analysis.dig('latency', 'avg_sec')&.round,
        # Детализация периодов, изменений и банков остаётся только в JSON.
        'periods' => metrics,
        'minute_change' => {
          'count_delta' => minute['count'] - previous['count'],
          'amount_delta' => minute['amount'] - previous['amount'],
          'count_change_pct' => ProviderMinuteMetrics.change(minute['count'], previous['count']),
          'amount_change_pct' => ProviderMinuteMetrics.change(minute['amount'], previous['amount'])
        },
        'targets' => targets,
        'minute_breakdown' => ProviderMinuteMetrics.breakdown(groups.fetch('minute').fetch(id, []), minute),
        'analysis_breakdown' => ProviderMinuteMetrics.breakdown(groups.fetch('analysis').fetch(id, []), analysis)
      }.merge(share_attributes(analysis, targets, at))
    end
    {
      'window_start_exclusive' => windows.fetch('analysis').fetch('start'),
      'window_end_inclusive' => end_at,
      'window_seconds' => @window_seconds,
      'window_mode' => @window_seconds ? 'rolling' : 'all_time',
      'windows' => windows, 'totals' => totals, 'providers' => rows,
      'definitions' => {
        'source' => 'operations_history.created_at; one recorded application per operation, all statuses',
        'daily' => 'UTC calendar day; approved operations created today, not payments completed today',
        'conversion_24h' => 'approved / all operations created in the last 24 hours; ratio 0..1',
        'analysis' => 'all retained history through window end by default; --window-seconds N selects (end - N seconds, end]',
        'avg_latency_sec' => 'all non-null latencies in the analysis window, rounded to integer seconds',
        'terminal_statuses' => ProviderMinuteMetrics::TERMINAL_STATUSES,
        'p95' => 'nearest rank: sorted[ceil(0.95 * count) - 1]',
        'breakdown_shares' => 'within this provider; analysis_breakdown uses the analysis window, minute_breakdown uses the last minute',
        'empty_denominator' => 'null; counts and amounts for empty cohorts are zero',
        'snapshot_limits' => 'full provider snapshot freshness is unknown; stats_calculated_at dates only recalculated metrics',
        'in_progress' => 'JSON-only minute counts and amounts; stored in_progress fields are not updated',
        'historical_at' => 'uses currently stored statuses, not a reconstruction of past status changes',
        'persisted_shares' => 'analysis window; percentage points for gaps, percentages for shares and target fulfillment',
        'requests_limits' => 'requests_last_minute and request limit utilization always use the last 60 seconds',
        'stats_window_sec' => 'analysis window length in seconds; null means all history through stats_calculated_at',
        'target_fulfillment' => 'actual share / target share * 100; null if no observations or target is absent/zero',
        'stats_calculated_at' => 'calculation reference time in UTC (window end; --at if supplied)'
      }
    }
  end

  private

  # Сопоставляем поля расчётных структур с колонками providers.
  # *_gap_pp — разность в процентных пунктах; *_pct — проценты.
  def share_attributes(analysis, targets, at)
    {
      'actual_count_share_pct' => analysis['count_share_pct'],
      'actual_volume_share_pct' => analysis['amount_share_pct'],
      'approved_volume_share_pct' => analysis['approved_amount_share_pct'],
      'count_target_fulfillment_pct' => targets['count_target_fulfillment_pct'],
      'volume_target_fulfillment_pct' => targets['volume_target_fulfillment_pct'],
      'count_share_gap_pp' => targets['count_share_gap_pp'],
      'volume_share_gap_pp' => targets['amount_share_gap_pp'],
      'approval_rate_pct' => analysis['approval_pct'],
      'rejection_rate_pct' => analysis['rejection_pct'],
      'expiration_rate_pct' => analysis['expiration_pct'],
      'approved_amount_pct' => analysis['approved_amount_pct'],
      'terminal_approval_rate_pct' => analysis['terminal_approval_pct'],
      'stats_calculated_at' => at.getutc.iso8601(6),
      'stats_window_sec' => @window_seconds
    }
  end

  # Скользящие окна: (начало, конец]. Предыдущая минута не пересекается с текущей.
  # Для календарного дня включаем полночь UTC: [00:00 UTC, конец].
  def period_windows(at)
    {
      'analysis' => [@window_seconds && at - @window_seconds, at, false],
      'minute' => [at - 60, at, false],
      'previous_minute' => [at - 120, at - 60, false],
      'last_hour' => [at - 3600, at, false],
      'last_24h' => [at - 86_400, at, false],
      'today_created_operations' => [Time.utc(at.year, at.month, at.day), at, true]
    }.transform_values do |start_at, end_at, inclusive|
      { 'start' => start_at&.iso8601(6), 'end' => end_at.iso8601(6), 'start_inclusive' => inclusive, 'end_inclusive' => true }
    end
  end

  # Минимальная схема для чтения. Поля назначения отдельно проверяются в run;
  # остальные таблицы проекта (очередь, решения, попытки) здесь не используются.
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

# CLI запускается только при прямом вызове файла; require_relative загружает класс.
if $PROGRAM_NAME == __FILE__
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

    # Оба режима выводят JSON в stdout; ошибки идут отдельно в stderr с кодом 1.
    puts JSON.pretty_generate(ProviderMinuteStats.new(**options).run)
  rescue ProviderMinuteStats::Error, SQLite3::Exception, OptionParser::ParseError,
         SystemCallError, ArgumentError => e
    warn "Provider statistics update failed: #{e.message}"
    exit 1
  end
end
