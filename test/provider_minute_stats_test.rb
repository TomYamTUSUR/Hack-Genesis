# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../bin/update_provider_minute_stats'

class ProviderMinuteStatsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SOURCE_DB = File.join(ROOT, 'DB', 'operations.db')
  AT = Time.iso8601('2026-09-05T12:00:00Z')

  def setup
    @source_hash = Digest::SHA256.file(SOURCE_DB).hexdigest
    @directory = Dir.mktmpdir('provider-minute-stats-')
    @path = File.join(@directory, 'operations.db')
    FileUtils.cp(SOURCE_DB, @path)
    @db = SQLite3::Database.new(@path)
    @db.results_as_hash = true
    @db.execute('DELETE FROM operations_history')
    @ids = @db.execute('SELECT payment_system, payment_system_id FROM providers').to_h do |row|
      [row['payment_system'], row['payment_system_id']]
    end
  end

  def teardown
    @db&.close
    FileUtils.remove_entry(@directory)
    assert_equal @source_hash, Digest::SHA256.file(SOURCE_DB).hexdigest
  end

  def operation(id, at:, amount:, provider: 'vipay', status: 'approved')
    @db.execute(<<~SQL, [id, at, amount, @ids.fetch(provider), status])
      INSERT INTO operations_history (operation_id, created_at, amount, payment_system_id, status)
      VALUES (?, ?, ?, ?, ?)
    SQL
  end

  def run_stats(at: AT)
    ProviderMinuteStats.new(database: @path, at: at).run
  end

  def stats(name)
    @db.get_first_row('SELECT requests_last_minute, in_progress_count, in_progress_amount FROM providers WHERE payment_system = ?', [name]).values
  end

  def tables_snapshot
    @db.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").to_h do |table|
      [table['name'], @db.execute("SELECT * FROM #{table['name']} ORDER BY rowid")]
    end
  end

  def test_boundaries_offsets_all_statuses_and_zero_providers
    operation('old', at: '2026-09-05T11:58:59Z', amount: 90_000)
    operation('lower', at: '2026-09-05T11:59:00Z', amount: 80_000)
    operation('inside', at: '2026-09-05T11:59:00.001Z', amount: 100)
    operation('offset', at: '2026-09-05T14:59:30+03:00', amount: 200, status: 'rejected')
    operation('upper', at: '2026-09-05T12:00:00Z', amount: 300, status: 'expired')
    operation('future', at: '2026-09-05T12:00:00.001Z', amount: 70_000)
    operation('second', at: '2026-09-05T11:59:50Z', amount: 400, provider: 'payflow', status: 'in_progress')
    before = tables_snapshot

    result = run_stats

    assert_equal [3, 3, 600], stats('vipay')
    assert_equal [1, 1, 400], stats('payflow')
    assert_equal [0, 0, 0], stats('quickpay')
    assert_equal [0, 0, 0], stats('spacepayments')
    assert_equal '2026-09-05T11:59:00.000000Z', result['window_start_exclusive']
    assert_equal '2026-09-05T12:00:00.000000Z', result['window_end_inclusive']
    after = tables_snapshot
    assert_equal before.reject { |key, _| key == 'providers' }, after.reject { |key, _| key == 'providers' }
    unchanged_fields = ->(rows) { rows.map { |row| row.reject { |key, _| %w[requests_last_minute in_progress_count in_progress_amount].include?(key) } } }
    assert_equal unchanged_fields.call(before['providers']), unchanged_fields.call(after['providers'])
  end

  def test_recalculation_is_idempotent_and_resets_expired_values
    operation('recent', at: '2026-09-05T11:59:30Z', amount: 500)
    result = run_stats
    before = tables_snapshot
    assert_equal result, run_stats
    assert_equal before, tables_snapshot
    run_stats(at: AT + 61)
    @ids.each_key { |name| assert_equal [0, 0, 0], stats(name) }
    assert_equal 1, @db.execute('PRAGMA table_info(providers)').count { |row| row['name'] == 'requests_last_minute' }
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

  def test_write_failure_rolls_back_values_and_new_column
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
    assert_equal 4, JSON.parse(output).fetch('providers').length
    assert_equal [1, 1, 500], stats('vipay')
  end
end
