require "csv"

module PaymentRouting
  module Importers
    # Читает data/operations_history.csv в таблицу operations_history.
    # Требует, чтобы providers уже были импортированы (payment_system -> id).
    class OperationsHistoryImporter
      include ProviderLookup

      def initialize(db:, history_file:)
        @db = db
        @history_file = history_file
      end

      def import
        rows = CSV.read(@history_file, headers: true)
        rows.each { |row| Upsert.by_key(@db[:operations_history], :operation_id, row["operation_id"], attrs_for(row)) }
        rows.size
      end

      private

      def attrs_for(row)
        {
          operation_id: row["operation_id"],
          created_at: row["created_at"],
          amount: row["amount"].to_i,
          bank: row["bank"],
          card_brand: row["card_brand"],
          payment_system_id: provider_id_for(@db, row["payment_system"]),
          status: row["status"],
          latency_sec: row["latency_sec"].to_i
        }
      end
    end
  end
end
