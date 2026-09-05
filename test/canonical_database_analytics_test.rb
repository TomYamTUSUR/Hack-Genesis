# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/canonical_database_analytics'
require_relative 'support/seeded_database'

class CanonicalDatabaseAnalyticsTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('canonical-database-analytics-')
    # Строит настоящую БД из data/* тем же путём, что и bin/import_data.rb -
    # так числа в этом тесте всегда соответствуют текущим data/*, а не
    # рассинхронизированному заранее закоммиченному бинарнику.
    @database_path = SeededDatabase.seed(File.join(@directory, 'operations.db'))
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_report_uses_canonical_database_without_modifying_it
    before = Digest::SHA256.file(@database_path).hexdigest
    analytics = RoutingAnalytics::CanonicalDatabaseAnalytics.new(@database_path)
    report = analytics.report(generated_at: Time.iso8601('2026-09-05T12:00:00+07:00'))
    analytics.close
    after = Digest::SHA256.file(@database_path).hexdigest

    assert_equal before, after
    assert_equal 'sqlite', report.dig('source', 'type')
    assert_equal 100, report['total_operations']
    assert_equal 10, report['pending_operations']
    assert_equal 110, report['all_operations_seen']
    assert_equal 3_391_500, report['total_amount']
    assert_equal 385_800, report.dig('pending_queue', 'total_amount')
    assert_equal 41, report.dig('distribution', 'vipay', 'count')
    assert_equal 19, report.dig('distribution', 'payflow', 'count')
    assert_equal 40, report.dig('distribution', 'quickpay', 'count')
    assert_equal 68, report.dig('status_summary', 'approved', 'count')
    assert_equal 'ok', report.dig('data_quality', 'database_integrity')
    assert_equal 11, report.dig('data_quality', 'foreign_key_definitions')
    assert_equal 0, report.dig('data_quality', 'database_orphans').values.sum
    assert_nil report['provider_snapshot_at']
    assert_nil report['gateway']
    assert_nil report['merchant']
  ensure
    analytics&.close
  end

  def test_report_remains_valid_json
    analytics = RoutingAnalytics::CanonicalDatabaseAnalytics.new(@database_path)
    report = analytics.report

    Dir.mktmpdir do |directory|
      path = File.join(directory, 'report.json')
      RoutingAnalytics::ReportWriter.write(path, report)
      parsed = JSON.parse(File.read(path, encoding: 'UTF-8'))

      assert_equal report['total_operations'], parsed['total_operations']
      assert_equal report['pending_operations'], parsed['pending_operations']
    end
  ensure
    analytics&.close
  end

  def test_noncanonical_schema_is_rejected_without_touching_source_database
    source_hash = Digest::SHA256.file(@database_path).hexdigest
    Dir.mktmpdir do |directory|
      copy_path = File.join(directory, 'operations.db')
      FileUtils.cp(@database_path, copy_path)
      copy = SQLite3::Database.new(copy_path)
      copy.execute('PRAGMA foreign_keys = OFF')
      copy.execute('DROP TABLE reference_decisions')
      copy.close
      copy = nil

      assert_raises(RoutingAnalytics::Error) do
        RoutingAnalytics::CanonicalDatabaseSource.new(copy_path)
      end
    ensure
      copy&.close
    end
    assert_equal source_hash, Digest::SHA256.file(@database_path).hexdigest
  end
end
