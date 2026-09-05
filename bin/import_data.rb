#!/usr/bin/env ruby
# Импортирует data/*.json,csv в SQLite (db/operations.db). Отдельный процесс от
# runtime-логики (strategies/rating) - её код к БД не обращается вообще.
#
# Использование:
#   bundle exec ruby bin/import_data.rb                    # всё, в порядке зависимостей
#   bundle exec ruby bin/import_data.rb providers history  # только перечисленные источники
#
# providers должен импортироваться до history - ей нужен payment_system_id.

require_relative "../lib/payment_routing"
require_relative "../db/database"
require_relative "../lib/payment_routing/importers/upsert"
require_relative "../lib/payment_routing/importers/provider_lookup"
require_relative "../lib/payment_routing/importers/providers_importer"
require_relative "../lib/payment_routing/importers/business_parameters_importer"
require_relative "../lib/payment_routing/importers/operations_queue_importer"
require_relative "../lib/payment_routing/importers/operations_history_importer"

module PaymentRouting
  module Importers
    class Cli
      # Порядок задаёт и очерёдность зависимостей (providers - первым,
      # business_parameters - сразу за ним, т.к. только обновляет уже
      # созданные строки), и список допустимых имён источников для CLI-аргументов.
      IMPORT_ORDER = %w[providers business_parameters queue history].freeze

      def initialize(db:, config:)
        @db = db
        @config = config
      end

      def run(requested)
        unknown = requested - IMPORT_ORDER
        raise ArgumentError, "Неизвестные источники: #{unknown.join(', ')} (доступны: #{IMPORT_ORDER.join(', ')})" unless unknown.empty?

        targets = requested.empty? ? IMPORT_ORDER : IMPORT_ORDER & requested
        targets.each { |name| import_one(name) }
      end

      private

      def import_one(name)
        count = importer_for(name).import
        puts "#{name}: #{count} записей"
      end

      def importer_for(name)
        case name
        when "providers" then ProvidersImporter.new(db: @db, providers_file: @config.providers_file)
        when "business_parameters" then BusinessParametersImporter.new(db: @db, business_parameters_file: @config.business_parameters_file)
        when "queue" then OperationsQueueImporter.new(db: @db, queue_file: @config.operations_queue_file)
        when "history" then OperationsHistoryImporter.new(db: @db, history_file: @config.operations_history_file)
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  db = PaymentRouting::Db.connect
  PaymentRouting::Db.create_schema!(db)
  PaymentRouting::Importers::Cli.new(db: db, config: PaymentRouting::RoutingConfig.new).run(ARGV)
end
