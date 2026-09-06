module PaymentRouting
  module Menu
    class DataManager
      Source = Struct.new(:key, :label, :table, keyword_init: true)

      CLEAR_ORDER = %i[
        routing_attempts eligible_providers provider_skip_reasons
        routing_decisions reference_decisions operations_history
        operations_queue providers
      ].freeze

      def initialize(db:, config:)
        @db = db
        @config = config
      end

      def sources
        [
          Source.new(key: "providers", label: File.basename(@config.providers_file), table: :providers),
          Source.new(key: "queue", label: File.basename(@config.operations_queue_file), table: :operations_queue),
          Source.new(key: "history", label: File.basename(@config.operations_history_file), table: :operations_history)
        ]
      end

      def update(key)
        count = importer_for(key).import
        "#{label_for(key)}: #{count} records added/updated"
      rescue StandardError => e
        "Error: #{e.message}"
      end

      def replace(key)
        source = sources.find { |s| s.key == key }
        @db[source.table].delete
        count = importer_for(key).import
        "#{source.label}: table cleared, #{count} records loaded"
      rescue StandardError => e
        "Error: #{e.message}"
      end

      def clear_all!
        CLEAR_ORDER.each { |table| @db[table].delete }
        "All database tables cleared"
      rescue StandardError => e
        "Error: #{e.message}"
      end

      private

      def label_for(key)
        sources.find { |s| s.key == key }.label
      end

      def importer_for(key)
        case key
        when "providers" then Importers::ProvidersImporter.new(db: @db, providers_file: @config.providers_file)
        when "queue" then Importers::OperationsQueueImporter.new(db: @db, queue_file: @config.operations_queue_file)
        when "history" then Importers::OperationsHistoryImporter.new(db: @db, history_file: @config.operations_history_file)
        end
      end
    end
  end
end
