# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../bin/update_provider_minute_stats'
require_relative 'support/seeded_database'

class ProviderMinuteStatsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  AT = Time.iso8601('2026-09-05T12:00:00Z')

  def setup
    @directory = Dir.mktmpdir('provider-minute-stats-')
    # Только providers - operations_history тестам нужна с нуля, своя
    # (контролируемые моменты времени), поэтому историю из data/ не грузим.
    @path = SeededDatabase.seed(File.join(@directory, 'operations.db'), queue: false, history: false)
    @db = SQLite3::Database.new(@path)
    @db.results_as_hash = true
    @ids = @db.execute('SELECT payment_system, payment_system_id FROM providers').to_h do |row|
      [row['payment_system'], row['payment_system_id']]
    end
  end

  def teardown
    @db&.close
    FileUtils.remove_entry(@directory)
  end

  def operation(id, at:, amount:, provider: 'vipay', status: 'approved', latency: nil, bank: 'sberbank')
    @db.execute(<<~SQL, [id, at, amount, @ids.fetch(provider), status, latency, bank])
      INSERT INTO operations_history (operation_id, created_at, amount, payment_system_id, status, latency_sec, bank)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    SQL
  end

  def run_stats(at: AT)
    ProviderMinuteStats.new(database: @path, at: at).run
  end

  # in_progress_count/amount больше не пишутся в БД (см. bin/update_provider_minute_stats.rb) -
  # значения минуты сравниваем по отчёту, а не по колонкам providers.
  def stats(report, name)
    row = report.fetch('providers').find { |r| r['payment_system'] == name }
    [row['requests_last_minute'], row.dig('periods', 'minute', 'amount')]
  end

  def tables_snapshot
    @db.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").to_h do |table|
      [table['name'], @db.execute("SELECT * FROM #{table['name']} ORDER BY rowid")]
    end
  end

  def test_recalculation_is_idempotent_and_resets_expired_values
    operation('recent', at: '2026-09-05T11:59:30Z', amount: 500)
    result = run_stats
    before = tables_snapshot
    # 'persistence' легитимно отличается между первым запуском (мигрирует
    # SHARE_COLUMNS) и вторым (они уже на месте) - сравниваем сам расчёт.
    without_persistence = ->(report) { report.reject { |key, _| key == 'persistence' } }
    assert_equal without_persistence.call(result), without_persistence.call(run_stats)
    assert_equal before, tables_snapshot
    result = run_stats(at: AT + 61)
    @ids.each_key { |name| assert_equal [0, 0], stats(result, name) }
    assert_equal 0, @db.execute('PRAGMA table_info(providers)').count { |row| row['name'] == 'requests_last_minute' }
  end

  def test_invalid_timestamp_does_not_change_database
    operation('bad-date', at: 'not-a-date', amount: 100)
    before = tables_snapshot
    error = assert_raises(ProviderMinuteStats::Error) { run_stats }
    assert_match(/bad-date/, error.message)
    assert_equal before, tables_snapshot
  end

  def test_invalid_amount_does_not_change_database
    operation('bad-amount', at: '2026-09-05T11:59:30Z', amount: 'invalid')
    before = tables_snapshot
    assert_raises(ProviderMinuteStats::Error) { run_stats }
    assert_equal before, tables_snapshot
  end

  def test_write_failure_rolls_back_all_provider_values
    operation('recent', at: '2026-09-05T11:59:30Z', amount: 100)
    @db.execute(<<~SQL)
      CREATE TRIGGER reject_stats BEFORE UPDATE ON providers
      WHEN NEW.payment_system = 'payflow'
      BEGIN SELECT RAISE(ABORT, 'test failure'); END;
    SQL
    before = tables_snapshot
    schema = @db.execute('SELECT sql FROM sqlite_master ORDER BY name')
    assert_raises(SQLite3::Exception) { run_stats }
    assert_equal before, tables_snapshot
    assert_equal schema, @db.execute('SELECT sql FROM sqlite_master ORDER BY name')
  end

  def test_cli_works_from_another_directory
    operation('recent', at: '2026-09-05T11:59:30Z', amount: 500)
    output, error, status = Open3.capture3(
      RbConfig.ruby, File.join(ROOT, 'bin', 'update_provider_minute_stats.rb'),
      '--database', @path, '--at', '2026-09-05T15:00:00+03:00', chdir: @directory
    )
    assert status.success?, error
    report = JSON.parse(output)
    assert_equal 4, report.fetch('providers').length
    assert_equal [1, 500], stats(report, 'vipay')
  end

  def test_empty_cohorts_and_zero_limits_have_null_rates
    @db.execute('UPDATE providers SET requests_per_minute_limit = 0, daily_amount_limit = 0')
    result = run_stats
    result['providers'].each do |row|
      assert_nil row['conversion_24h']
      assert_nil row['avg_latency_sec']
      assert_nil row.dig('periods', 'minute', 'approval_pct')
      assert_nil row.dig('periods', 'minute', 'count_share_pct')
      assert_nil row.dig('periods', 'minute', 'amount_share_pct')
      assert_nil row.dig('targets', 'requests_limit_utilization_pct')
      assert_nil row.dig('targets', 'snapshot_daily_limit_utilization_pct')
      assert_nil row.dig('minute_change', 'count_change_pct')
    end
  end

  def test_day_includes_midnight_and_amount_band_boundaries_are_exclusive
    [0, 999, 1000, 9999, 10_000, 49_999, 50_000, 99_999, 100_000].each_with_index do |amount, index|
      operation("band#{index}", at: '2026-09-05T00:00:00Z', amount: amount)
    end
    result = run_stats(at: Time.iso8601('2026-09-05T00:00:30Z'))
    vipay = result['providers'].find { |row| row['payment_system'] == 'vipay' }
    assert_equal 9, vipay.dig('periods', 'today_created_operations', 'count')
    assert_equal [2, 2, 2, 2, 1], vipay.dig('minute_breakdown', 'amount_bands').map { |row| row['count'] }
    assert_equal 100, vipay.dig('periods', 'minute', 'approval_pct')
  end

  def test_existing_requests_column_is_updated_without_schema_changes
    @db.execute('ALTER TABLE providers ADD COLUMN requests_last_minute INTEGER')
    requests_last_minute_ddl = @db.get_first_value("SELECT sql FROM sqlite_master WHERE name = 'providers'")
    operation('recent', at: '2026-09-05T11:59:30Z', amount: 100)
    result = run_stats
    assert_includes result.dig('persistence', 'columns'), 'requests_last_minute'
    assert_equal 1, @db.get_first_value("SELECT requests_last_minute FROM providers WHERE payment_system = 'vipay'")
    # requests_last_minute уже существовала - её самой заново не добавляют
    # (не дублируется в DDL); SHARE_COLUMNS по-прежнему законно добавляются.
    providers_ddl = @db.get_first_value("SELECT sql FROM sqlite_master WHERE name = 'providers'")
    assert_equal 1, providers_ddl.scan('requests_last_minute').size
    assert_includes requests_last_minute_ddl, 'requests_last_minute'
  end

  def test_dry_run_is_read_only_and_keeps_canonical_analyzer_compatible
    operation('recent', at: '2026-09-05T11:59:30Z', amount: 500)
    before = Digest::SHA256.file(@path).hexdigest
    output, error, status = Open3.capture3(
      RbConfig.ruby, File.join(ROOT, 'bin', 'update_provider_minute_stats.rb'),
      '--database', @path, '--at', AT.iso8601, '--dry-run'
    )
    assert status.success?, error
    assert JSON.parse(output).dig('persistence', 'dry_run')
    assert_equal before, Digest::SHA256.file(@path).hexdigest
    run_stats
    require_relative '../lib/canonical_database_analytics'
    source = RoutingAnalytics::CanonicalDatabaseSource.new(@path)
    assert_equal 4, source.analysis_inputs.fetch(:provider_data).fetch('providers').length
  ensure
    source&.close
  end
end
