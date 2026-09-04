require "json"

module PaymentRouting
  module Importers
    # Читает data/operations_queue_*.json 1:1 в таблицу operations_queue.
    class OperationsQueueImporter
      def initialize(db:, queue_file:)
        @db = db
        @queue_file = queue_file
      end

      def import
        raw_operations = JSON.parse(File.read(@queue_file))
        raw_operations.each { |raw| Upsert.by_key(@db[:operations_queue], :operation_id, raw["operation_id"], attrs_for(raw)) }
        raw_operations.size
      end

      private

      def attrs_for(raw)
        sbp = raw.dig("payout_requisite", "sbp") || {}

        {
          operation_id: raw["operation_id"],
          created_at: raw["created_at"],
          amount: raw["amount"],
          bank: raw["bank"],
          card_brand: raw["card_brand"],
          payout_requisite_sbp_phone: sbp["phone"],
          payout_requisite_bank_name: sbp["bank_name"]
        }
      end
    end
  end
end
