# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/routing_analytics'
require_relative 'support/seeded_database'

class RoutingAnalyticsTest < Minitest::Test
  def with_seeded_database(providers: true, queue: true, history: true)
    Dir.mktmpdir do |directory|
      path = SeededDatabase.seed(File.join(directory, 'operations.db'), providers: providers, queue: queue, history: history)
      yield path
    end
  end

  def report_from(path)
    source = RoutingAnalytics::DatabaseSource.new(path)
    RoutingAnalytics::Analyzer.new(**source.analysis_inputs)
      .report(generated_at: Time.iso8601('2026-07-30T09:00:00+03:00'))
  ensure
    source&.close
  end

  def test_database_import_and_existing_history_report
    with_seeded_database do |path|
      report = report_from(path)

      assert_equal 100, report['total_operations']
      assert_equal 10, report['pending_operations']
      assert_equal 110, report['all_operations_seen']
      assert_equal 385_800, report.dig('pending_queue', 'total_amount')
      assert_equal 3_391_500, report['total_amount']
      assert_equal 100, report.dig('daily_distribution', '2026-07-29', 'total_operations')
      assert_equal '2026-07-29', report['recommendation_period']
      # snapshot_at/gateway/merchant не хранятся в канонической схеме (нет для них колонок) -
      # см. DatabaseSource#provider_data / CanonicalDatabaseSource#provider_data.
      assert_nil report['gateway']
      assert_nil report['merchant']
      assert_equal 41, report.dig('distribution', 'vipay', 'count')
      assert_equal 19, report.dig('distribution', 'payflow', 'count')
      assert_equal 40, report.dig('distribution', 'quickpay', 'count')
      assert_equal 68, report.dig('status_summary', 'approved', 'count')
      assert_equal 0, report.dig('data_quality', 'history_timestamp_backward_transitions')
      assert_equal 29, report.dig('data_quality', 'history_current_bank_rule_mismatch_count')
      assert_equal 'ok', report.dig('data_quality', 'database_integrity')
      assert_equal 0, report.dig('data_quality', 'database_orphans').values.sum
      assert_empty report['skip_reasons']
    end
  end

  def test_database_logging_replaces_current_operation_state
    with_seeded_database(queue: false, history: false) do |path|
      operation = {
        'operation_id' => 'op_new',
        'created_at' => '2026-07-30T10:00:00+03:00',
        'amount' => 10_000,
        'bank' => 'sberbank',
        'payout_requisite' => { 'sbp' => { 'phone' => '79000000000' } }
      }
      # routing_decisions.operation_id -> operations_queue.operation_id (см. ER-диаграмму) -
      # операция должна быть в operations_queue до того, как на неё сошлётся
      # решение; log_operations не удаляет её оттуда (см. комментарий в самом
      # методе) - "обработанность" видна по наличию записи в
      # operations_history/routing_decisions, а не по отсутствию в очереди.
      seed_db = SQLite3::Database.new(path)
      seed_db.execute(
        'INSERT INTO operations_queue (operation_id, created_at, amount, bank) VALUES (?, ?, ?, ?)',
        [operation['operation_id'], operation['created_at'], operation['amount'], operation['bank']]
      )
      seed_db.close
      first_decision = {
        'operation_id' => 'op_new',
        'selected_provider' => 'vipay',
        'attempts' => [{ 'provider' => 'vipay', 'decision' => 'selected', 'reason' => 'highest_score' }],
        'simulated_result' => 'approved',
        'latency_sec' => 30
      }
      latest_decision = {
        'operation_id' => 'op_new',
        'selected_provider' => 'payflow',
        'attempts' => [
          { 'provider' => 'vipay', 'decision' => 'skipped', 'reason' => 'provider_timeout' },
          { 'provider' => 'payflow', 'decision' => 'selected', 'reason' => 'fallback_candidate' }
        ],
        'simulated_result' => 'approved',
        'latency_sec' => 45
      }

      writer = RoutingAnalytics::DatabaseWriter.new(path)
      writer.log_operations(operations: [operation], decisions: [first_decision])
      writer.log_operations(operations: [operation], decisions: [latest_decision])
      writer.close
      writer = nil

      report = report_from(path)
      database = SQLite3::Database.new(path, flags: SQLite3::Constants::Open::READONLY)

      assert_equal 1, report['total_operations']
      assert_equal 0, report['pending_operations']
      assert_equal 1, report.dig('distribution', 'payflow', 'count')
      assert_equal 0, report.dig('distribution', 'vipay', 'count')
      assert_equal 1, report.dig('skip_reasons', 'provider_timeout')
      assert_equal 2, database.get_first_value('SELECT COUNT(*) FROM routing_attempts')
      # operations_queue не чистится (см. комментарий в log_operations) - "не в
      # ожидании" видно по report['pending_operations'] выше, а не по этой таблице.
      assert_equal 1, database.get_first_value('SELECT COUNT(*) FROM operations_queue')
      refute database.execute("SELECT name FROM sqlite_master WHERE sql LIKE '%phone%' AND name = 'operations_history'").any?
      database.close
    ensure
      writer&.close
      database&.close
    end
  end

  def test_database_source_is_read_only
    with_seeded_database do |path|
      before = Digest::SHA256.file(path).hexdigest
      report_from(path)
      after = Digest::SHA256.file(path).hexdigest

      assert_equal before, after
    end
  end

  def test_report_writer_creates_valid_json
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'report.json')
      RoutingAnalytics::ReportWriter.write(path, { 'total_operations' => 1 })

      assert_equal({ 'total_operations' => 1 }, JSON.parse(File.read(path, encoding: 'UTF-8')))
    end
  end

  def test_protected_source_directories_cannot_be_write_targets
    Dir.mktmpdir do |directory|
      protected_root = File.join(directory, 'data')
      FileUtils.mkdir_p(protected_root)

      assert_raises(RoutingAnalytics::Error) do
        RoutingAnalytics::DatabaseWriter.new(
          File.join(protected_root, 'operations.db'),
          protected_roots: [protected_root]
        )
      end
      assert_raises(RoutingAnalytics::Error) do
        RoutingAnalytics::ReportWriter.write(
          File.join(protected_root, 'report.json'),
          {},
          protected_roots: [protected_root]
        )
      end
    end
  end
end
