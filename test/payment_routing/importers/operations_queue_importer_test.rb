require_relative "../../test_helper"

module PaymentRouting
  module Importers
    class OperationsQueueImporterTest < Minitest::Test
      def setup
        @db = Db.connect(nil)
        Db.create_schema!(@db)
        @importer = OperationsQueueImporter.new(db: @db, queue_file: RoutingConfig.new.operations_queue_file)
      end

      def test_imports_every_operation_from_the_queue_file
        assert_equal 10, @importer.import
      end

      def test_flattens_the_nested_sbp_payout_requisite
        @importer.import

        op_103 = @db[:operations_queue].where(operation_id: "op_103").first
        assert_equal "79001112233", op_103[:payout_requisite_sbp_phone]
        assert_equal "Сбербанк", op_103[:payout_requisite_bank_name]
      end
    end
  end
end
