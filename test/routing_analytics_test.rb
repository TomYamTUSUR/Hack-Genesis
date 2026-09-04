# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/routing_analytics'

class RoutingAnalyticsTest < Minitest::Test
  PROJECT_ROOT = File.expand_path('..', __dir__)

  def provider_data
    RoutingAnalytics::Loader.providers(File.join(PROJECT_ROOT, 'data', 'providers.json'))
  end

  def history_rows
    RoutingAnalytics::Loader.history(File.join(PROJECT_ROOT, 'data', 'operations_history.csv'))
  end

  def pending_operations
    RoutingAnalytics::Loader.json_array(File.join(PROJECT_ROOT, 'data', 'operations_queue_10.json'))
  end

  def test_existing_history_report
    report = RoutingAnalytics::Analyzer.new(
      provider_data: provider_data,
      history_rows: history_rows,
      pending_operations: pending_operations
    ).report(generated_at: Time.iso8601('2026-07-30T09:00:00+03:00'))

    assert_equal 100, report['total_operations']
    assert_equal 10, report['pending_operations']
    assert_equal 110, report['all_operations_seen']
    assert_equal 385_800, report.dig('pending_queue', 'total_amount')
    assert_equal 3_391_500, report['total_amount']
    assert_equal 100, report.dig('daily_distribution', '2026-07-29', 'total_operations')
    assert_equal '2026-07-29', report['recommendation_period']
    assert_equal 41, report.dig('distribution', 'vipay', 'count')
    assert_equal 19, report.dig('distribution', 'payflow', 'count')
    assert_equal 40, report.dig('distribution', 'quickpay', 'count')
    assert_equal 68, report.dig('status_summary', 'approved', 'count')
    assert_equal 48, report.dig('data_quality', 'history_timestamp_backward_transitions')
    assert_equal 29, report.dig('data_quality', 'history_current_bank_rule_mismatch_count')
    assert_empty report['skip_reasons']
  end

  def test_journal_redacts_phone_and_latest_event_wins_in_analytics
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'operations.jsonl')
      journal = RoutingAnalytics::OperationJournal.new(path)
      operation = {
        'operation_id' => 'op_new',
        'created_at' => '2026-07-30T10:00:00+03:00',
        'amount' => 10_000,
        'bank' => 'sberbank',
        'payout_requisite' => { 'sbp' => { 'phone' => '79000000000', 'bank_name' => 'Сбербанк' } }
      }
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

      journal.append(operation: operation, decision: first_decision)
      journal.append(operation: operation, decision: latest_decision)
      events = journal.read_all

      assert_equal '[REDACTED]', events.first.dig('operation', 'payout_requisite', 'sbp', 'phone')

      report = RoutingAnalytics::Analyzer.new(
        provider_data: provider_data,
        history_rows: [],
        journal_events: events,
        pending_operations: [operation]
      ).report

      assert_equal 1, report['total_operations']
      assert_equal 0, report['pending_operations']
      assert_equal 1, report.dig('distribution', 'payflow', 'count')
      assert_equal 0, report.dig('distribution', 'vipay', 'count')
      assert_equal 1, report.dig('skip_reasons', 'provider_timeout')
      assert_equal 1, report.dig('data_quality', 'journal_replayed_events')
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
        journal = RoutingAnalytics::OperationJournal.new(
          File.join(protected_root, 'operations.jsonl'),
          protected_roots: [protected_root]
        )
        journal.append(
          operation: { 'operation_id' => 'op_guard' },
          decision: { 'operation_id' => 'op_guard', 'selected_provider' => 'vipay', 'attempts' => [] }
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
