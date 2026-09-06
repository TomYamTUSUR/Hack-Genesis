require_relative "../../test_helper"
require_relative "../../../lib/payment_routing/menu/data_manager"

module PaymentRouting
  module Menu
    class DataManagerTest < Minitest::Test
      def setup
        @db = Db.connect(nil)
        Db.create_schema!(@db)
        @config = RoutingConfig.new
        @manager = DataManager.new(db: @db, config: @config)
      end

      def test_sources_lists_the_three_data_files
        labels = @manager.sources.map(&:label)
        assert_equal %w[providers.json operations_queue_10.json operations_history.csv], labels
      end

      def test_update_imports_providers_without_duplicating_on_a_second_call
        @manager.update("providers")
        first_count = @db[:providers].count
        message = @manager.update("providers")

        assert_equal first_count, @db[:providers].count
        assert_match(/added\/updated/, message)
      end

      def test_replace_clears_the_table_before_reimporting
        @manager.update("providers")
        @db[:providers].where(payment_system: "vipay").update(traffic_percentage: 999)

        @manager.replace("providers")

        refute_equal 999, @db[:providers].where(payment_system: "vipay").get(:traffic_percentage)
      end

      def test_replace_surfaces_foreign_key_errors_instead_of_crashing
        @manager.update("providers")
        @manager.update("queue")
        id = @db[:providers].get(:payment_system_id)
        @db[:routing_decisions].insert(operation_id: @db[:operations_queue].get(:operation_id),
                                       selected_payment_system_id: id, simulated_result: "approved",
                                       latency_sec: 1, created_at: Time.now)

        message = @manager.replace("providers")

        assert_match(/Error/, message)
      end

      def test_clear_all_empties_every_table
        @manager.update("providers")
        @manager.update("queue")
        @manager.update("history")

        @manager.clear_all!

        DataManager::CLEAR_ORDER.each { |table| assert_equal 0, @db[table].count }
      end
    end
  end
end
