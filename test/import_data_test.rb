# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../bin/import_data'

class ImportDataTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SOURCE_DB = File.join(ROOT, 'DB', 'operations.db')

  def setup
    @original_hash = Digest::SHA256.file(SOURCE_DB).hexdigest
    @directory = Dir.mktmpdir('import-data-test-')
    @path = File.join(@directory, 'operations.db')
    FileUtils.cp(SOURCE_DB, @path)
    @data_dir = File.join(ROOT, 'data')
    @db = SQLite3::Database.new(@path)
    # Only clear the disposable database copy; retain the actual project schema.
    DataImporter::TABLE_KEYS.each_key { |table| @db.execute("DELETE FROM #{table}") }
    @db.execute('DELETE FROM sqlite_sequence')
  end

  def teardown
    @db&.close
    FileUtils.remove_entry(@directory)
    assert_equal @original_hash, Digest::SHA256.file(SOURCE_DB).hexdigest
  end

  def import(**options)
    DataImporter.new(database: @path, data_dir: @data_dir, **options).run
  end

  def snapshot
    (DataImporter::TABLE_KEYS.keys + ['sqlite_sequence']).to_h do |table|
      [table, @db.execute("SELECT * FROM #{table} ORDER BY rowid")]
    end
  end

  def test_import_maps_sources_and_preserves_schema
    schema = @db.execute('SELECT sql FROM sqlite_master ORDER BY name')
    counts = import

    assert_equal 4, counts['providers'][:inserted]
    assert_equal 100, counts['operations_history'][:inserted]
    assert_equal 10, counts['operations_queue'][:inserted]
    assert_equal 4, counts['reference_decisions'][:inserted]
    assert_equal 17, counts['eligible_providers'][:inserted]
    assert_equal 13, counts['provider_skip_reasons'][:inserted]
    assert_equal 0, counts['routing_decisions'][:inserted]
    assert_equal 3_391_500, @db.get_first_value('SELECT SUM(amount) FROM operations_history')
    assert_equal ['79001234567', 'Сбербанк'], @db.get_first_row(
      "SELECT payout_requisite_sbp_phone, payout_requisite_bank_name FROM operations_queue WHERE operation_id = 'op_101'"
    )
    assert_equal ['["sberbank","tinkoff","vtb"]', 0], @db.get_first_row(
      "SELECT banks, exclude_banks FROM providers WHERE payment_system = 'vipay'"
    )
    assert_nil @db.get_first_value("SELECT limit_amount_min FROM providers WHERE payment_system = 'spacepayments'")
    assert_equal 'vipay', @db.get_first_value(
      "SELECT payment_system FROM operations_history JOIN providers USING (payment_system_id) WHERE operation_id = 'op_001'"
    )
    assert_empty @db.execute('PRAGMA foreign_key_check')
    assert_equal schema, @db.execute('SELECT sql FROM sqlite_master ORDER BY name')
  end

  def test_sample_is_opt_in_and_repeated_import_is_unchanged
    counts = import(include_sample: true)
    assert_equal 10, counts['routing_decisions'][:inserted]
    sample = JSON.parse(File.read(File.join(@data_dir, 'sample_routing_decisions.json')))
    assert_equal sample.sum { |row| row.fetch('attempts').length }, counts['routing_attempts'][:inserted]
    before = snapshot
    assert_equal 0, import(include_sample: true).values.sum { |count| count[:inserted] }
    assert_equal before, snapshot
    assert_empty @db.execute('PRAGMA foreign_key_check')
  end

  def test_existing_values_and_provider_ids_are_preserved
    @db.execute("INSERT INTO providers (payment_system_id, payment_system, status) VALUES (99, 'vipay', 'disabled')")
    import
    assert_equal [99, 'disabled'], @db.get_first_row(
      "SELECT payment_system_id, status FROM providers WHERE payment_system = 'vipay'"
    )
    assert_equal 99, @db.get_first_value("SELECT payment_system_id FROM operations_history WHERE operation_id = 'op_001'")
    import(include_sample: true)
    @db.execute("UPDATE routing_decisions SET simulated_result = 'rejected' WHERE operation_id = 'op_101'")
    before = snapshot
    import(include_sample: true)
    assert_equal before, snapshot
  end

  def test_failure_rolls_back_all_tables
    copied_data = File.join(@directory, 'data')
    FileUtils.cp_r(@data_dir, copied_data)
    @data_dir = copied_data
    references_path = File.join(@data_dir, 'reference_decisions.json')
    references = JSON.parse(File.read(references_path))
    references['deterministic_cases'][0]['required_provider'] = 'unknown-provider'
    File.write(references_path, JSON.generate(references))
    before = snapshot
    error = assert_raises(DataImporter::Error) { import }
    assert_match(/Unknown provider/, error.message)
    assert_equal before, snapshot
  end

  def test_cli_on_copy_of_current_database_from_another_directory
    populated_path = File.join(@directory, 'populated.db')
    FileUtils.cp(SOURCE_DB, populated_path)
    output, error, status = Open3.capture3(
      RbConfig.ruby, File.join(ROOT, 'bin', 'import_data.rb'),
      '--database', populated_path, chdir: @directory
    )
    assert status.success?, error
    assert_match(/Import complete:/, output)
    assert_match(/Sample decisions excluded/, output)
    copy = SQLite3::Database.new(populated_path)
    assert_equal 100, copy.get_first_value('SELECT COUNT(*) FROM operations_history')
    assert_equal 10, copy.get_first_value('SELECT COUNT(*) FROM operations_queue')
    assert_equal 17, copy.get_first_value('SELECT COUNT(*) FROM eligible_providers')
    assert_empty copy.execute('PRAGMA foreign_key_check')
  ensure
    copy&.close
  end
end
