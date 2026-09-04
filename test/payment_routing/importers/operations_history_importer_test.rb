require_relative "../../test_helper"

module PaymentRouting
  module Importers
    class OperationsHistoryImporterTest < Minitest::Test
      def setup
        @db = Db.connect(nil)
        Db.create_schema!(@db)
        @importer = OperationsHistoryImporter.new(db: @db, history_file: RoutingConfig.new.operations_history_file)
      end

      def test_raises_a_clear_error_when_providers_have_not_been_imported_yet
        error = assert_raises(RuntimeError) { @importer.import }
        assert_match(/не найден в providers/, error.message)
      end

      def test_resolves_payment_system_name_to_its_id_once_providers_are_imported
        ProvidersImporter.new(db: @db, providers_file: RoutingConfig.new.providers_file).import

        count = @importer.import

        assert_equal 100, count
        quickpay_id = @db[:providers].where(payment_system: "quickpay").first[:payment_system_id]
        assert_equal quickpay_id, @db[:operations_history].where(operation_id: "op_050").first[:payment_system_id]
      end
    end
  end
end
