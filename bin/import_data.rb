#!/usr/bin/env ruby
# frozen_string_literal: true

# Import data/ into the existing schema from DB/create_tables.rb.
# Existing rows are preserved. The entire import is committed or rolled back.
# Provider snapshot metadata (snapshot_at, gateway, merchant) and the reference
# description have no columns in this schema and are not persisted.
# Eligibility and skip reasons are reference expectations, not routing results.
# Usage: ruby bin/import_data.rb [--data-dir PATH] [--database PATH]
#        [--include-sample]

require 'csv'
require 'json'
require 'optparse'
require 'sqlite3'

class DataImporter
  class Error < StandardError; end

  TABLE_KEYS = {
    'providers' => %w[payment_system],
    'operations_queue' => %w[operation_id],
    'operations_history' => %w[operation_id],
    'reference_decisions' => %w[operation_id],
    'eligible_providers' => %w[operation_id payment_system_id],
    'provider_skip_reasons' => %w[operation_id payment_system_id reason],
    'routing_decisions' => %w[operation_id],
    'routing_attempts' => %w[operation_id attempt_number]
  }.freeze
  HISTORY_COLUMNS = %w[operation_id created_at amount bank card_brand payment_system status latency_sec].freeze

  def initialize(database:, data_dir:, include_sample: false)
    @path = File.expand_path(database)
    @data_dir = File.expand_path(data_dir)
    @include_sample = include_sample
    @counts = TABLE_KEYS.to_h { |table, _| [table, { inserted: 0, skipped: 0 }] }
  end

  def run
    raise Error, "Database does not exist: #{@path}. Create it with DB/create_tables.rb first." unless File.file?(@path)

    providers = read_json('providers.json').fetch('providers')
    queue_name = File.file?(File.join(@data_dir, 'operations_queue.json')) ? 'operations_queue.json' : 'operations_queue_10.json'
    queue = read_json(queue_name)
    references = read_json('reference_decisions.json')
    history = CSV.read(File.join(@data_dir, 'operations_history.csv'), headers: true, encoding: 'bom|utf-8')
    missing = HISTORY_COLUMNS - (history.headers || [])
    raise Error, "Missing CSV columns: #{missing.join(', ')}" unless missing.empty?

    sample = @include_sample ? read_json('sample_routing_decisions.json') : []
    { providers: providers, queue: queue, sample: sample }.each do |name, rows|
      raise Error, "#{name}: expected an array of objects" unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) }
    end

    @db = SQLite3::Database.new(@path, flags: SQLite3::Constants::Open::READWRITE)
    @db.busy_timeout = 5000
    @db.execute('PRAGMA foreign_keys = ON')
    @columns = TABLE_KEYS.to_h do |table, _|
      columns = @db.execute("PRAGMA table_info(#{table})").map { |row| row[1] }
      raise Error, "Missing table: #{table}" if columns.empty?

      [table, columns]
    end

    @db.transaction(:immediate) do
      providers.each do |provider|
        insert('providers', provider.reject { |key, _| key == 'payment_system_id' })
      end
      @provider_ids = @db.execute('SELECT payment_system, payment_system_id FROM providers').to_h

      queue.each do |operation|
        attributes = operation.reject { |key, _| key == 'payout_requisite' }
        attributes['payout_requisite_sbp_phone'] = operation.dig('payout_requisite', 'sbp', 'phone')
        attributes['payout_requisite_bank_name'] = operation.dig('payout_requisite', 'sbp', 'bank_name')
        insert('operations_queue', attributes)
      end

      history.each do |row|
        attributes = row.to_h
        attributes['payment_system_id'] = provider_id(attributes.delete('payment_system'))
        %w[amount latency_sec].each do |key|
          attributes[key] = attributes[key].nil? || attributes[key].empty? ? nil : Integer(attributes[key], 10)
        end
        insert('operations_history', attributes)
      end

      references.fetch('deterministic_cases').each do |row|
        insert('reference_decisions', {
          'operation_id' => row.fetch('operation_id'),
          'required_payment_system_id' => provider_id(row.fetch('required_provider')),
          'reason' => row.fetch('reason')
        })
      end
      references.fetch('eligible_providers', {}).each do |operation_id, names|
        names.each do |name|
          insert('eligible_providers', {
            'operation_id' => operation_id, 'payment_system_id' => provider_id(name), 'is_eligible' => true
          })
        end
      end
      references.fetch('skip_reasons_expected', {}).each do |operation_id, reasons|
        reasons.each do |name, reason|
          insert('provider_skip_reasons', {
            'operation_id' => operation_id, 'payment_system_id' => provider_id(name), 'reason' => reason
          })
        end
      end

      sample.each { |decision| import_sample(decision) }
      raise Error, 'Foreign key check failed; import rolled back' unless @db.execute('PRAGMA foreign_key_check').empty?
    end
    @counts
  ensure
    @db&.close
  end

  private

  def read_json(name)
    JSON.parse(File.read(File.join(@data_dir, name), encoding: 'bom|utf-8'))
  end

  def provider_id(name)
    @provider_ids.fetch(name) { raise Error, "Unknown provider: #{name.inspect}" }
  end

  def insert(table, attributes)
    keys = TABLE_KEYS.fetch(table)
    keys.each do |key|
      raise Error, "#{table}: missing #{key}" if attributes[key].nil? || attributes[key].to_s.empty?
    end
    unknown = attributes.keys - @columns.fetch(table)
    raise Error, "#{table}: unsupported columns: #{unknown.join(', ')}" unless unknown.empty?

    # Check before INSERT so retries do not advance AUTOINCREMENT sequences.
    where = keys.map { |key| "#{key} = ?" }.join(' AND ')
    if @db.get_first_value("SELECT 1 FROM #{table} WHERE #{where}", keys.map { |key| sql_value(attributes[key]) })
      @counts[table][:skipped] += 1
      return false
    end

    columns = attributes.keys
    placeholders = Array.new(columns.length, '?').join(', ')
    @db.execute("INSERT INTO #{table} (#{columns.join(', ')}) VALUES (#{placeholders})",
                attributes.values.map { |value| sql_value(value) })
    @counts[table][:inserted] += 1
    true
  end

  def sql_value(value)
    case value
    when true then 1
    when false then 0
    when Array, Hash then JSON.generate(value)
    else value
    end
  end

  def import_sample(decision)
    operation_id = decision.fetch('operation_id')
    inserted = insert('routing_decisions', {
      'operation_id' => operation_id,
      'selected_payment_system_id' => provider_id(decision.fetch('selected_provider')),
      'simulated_result' => decision.fetch('simulated_result'),
      'latency_sec' => decision.fetch('latency_sec'),
      'created_at' => decision['created_at']
    })
    return unless inserted # Do not attach sample attempts to an existing real decision.

    decision.fetch('attempts').each_with_index do |attempt, index|
      insert('routing_attempts', {
        'operation_id' => operation_id, 'payment_system_id' => provider_id(attempt.fetch('provider')),
        'attempt_number' => index + 1, 'decision' => attempt.fetch('decision'),
        'reason' => attempt.fetch('reason'), 'created_at' => attempt['created_at']
      })
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path('..', __dir__)
  options = { database: File.join(root, 'DB', 'operations.db'), data_dir: File.join(root, 'data') }
  begin
    parser = OptionParser.new do |cli|
      cli.banner = 'Usage: ruby bin/import_data.rb [options]'
      cli.separator 'Imports into the existing schema; preserves existing rows and does not change tables.'
      cli.on('--database PATH', 'SQLite database (default: DB/operations.db)') { |value| options[:database] = value }
      cli.on('--data-dir PATH', 'Source folder (default: data/)') { |value| options[:data_dir] = value }
      cli.on('--include-sample', 'Also import demonstration decisions and attempts') { options[:include_sample] = true }
      cli.on('-h', '--help', 'Show help') { puts cli; exit }
    end
    parser.parse!
    raise OptionParser::InvalidArgument, ARGV.join(' ') unless ARGV.empty?

    counts = DataImporter.new(**options).run
    puts "Import complete: #{File.expand_path(options[:database])}"
    counts.each { |table, count| puts "#{table}: inserted=#{count[:inserted]}, skipped=#{count[:skipped]}" }
    puts 'Sample decisions excluded; use --include-sample to import them.' unless options[:include_sample]
  rescue DataImporter::Error, SQLite3::Exception, JSON::ParserError, CSV::MalformedCSVError,
         OptionParser::ParseError, SystemCallError, KeyError, ArgumentError, TypeError, NoMethodError => e
    warn "Import failed: #{e.message}"
    exit 1
  end
end
