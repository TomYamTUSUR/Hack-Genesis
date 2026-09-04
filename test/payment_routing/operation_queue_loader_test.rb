require_relative "../test_helper"

module PaymentRouting
  class OperationQueueLoaderTest < Minitest::Test
    include TestFactories

    def setup
      @operations = OperationQueueLoader.new(db: seeded_db).load
    end

    def test_loads_every_operation_from_the_queue_table
      assert_equal 10, @operations.size
    end

    def test_parses_fields_of_a_known_operation
      op_103 = @operations.find { |op| op.operation_id == "op_103" }

      assert_equal 150_000, op_103.amount
      assert_equal "sberbank", op_103.bank
    end
  end
end
