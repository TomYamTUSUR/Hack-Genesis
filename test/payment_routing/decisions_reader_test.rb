require_relative "../test_helper"
require_relative "../support/seeded_database"
require_relative "../../lib/routing_analytics"
require "tmpdir"

module PaymentRouting
  class DecisionsReaderTest < Minitest::Test
    def test_reconstructs_exactly_what_the_router_produced_in_memory
      Dir.mktmpdir do |directory|
        path = SeededDatabase.seed(File.join(directory, "operations.db"))

        db = Db.connect(path)
        config = RoutingConfig.new
        rated_and_fallback = config.rated_providers + [config.fallback_provider]
        providers = ProviderRegistry.new(db: db, rated_providers: rated_and_fallback).load
        actuals = HistoricalActualsProvider.new(db: db).load
        operations = OperationQueueLoader.new(db: db).load
        state = Router::RunState.new(providers: providers, actuals_by_provider: actuals)
        strategy_registry = Strategies::StrategyRegistry.new(strategies_file: config.strategies_file)
        router = Router::Router.new(
          state: state, rated_payment_systems: config.rated_providers, fallback_payment_system: config.fallback_provider,
          strategy_registry: strategy_registry, active_strategies: config.active_strategies
        )
        decisions = router.route_all(operations)
        db.disconnect

        writer = RoutingAnalytics::DatabaseWriter.new(path)
        operations_by_id = operations.to_h { |operation| [operation.operation_id, { "operation_id" => operation.operation_id, "amount" => operation.amount, "bank" => operation.bank }] }
        writer.log_operations(
          operations: decisions.map { |decision| operations_by_id.fetch(decision.operation_id) },
          decisions: decisions.map(&:to_h)
        )
        writer.close

        reader_db = Db.connect(path)
        reconstructed = DecisionsReader.new(db: reader_db).load
        reader_db.disconnect

        assert_equal decisions.map(&:to_h), reconstructed
      end
    end

    def test_raises_when_a_queue_operation_has_no_decision_yet
      db = Db.connect(nil)
      Db.create_schema!(db)
      db[:operations_queue].insert(operation_id: "op_1", created_at: "2026-01-01T00:00:00Z", amount: 1000, bank: "sberbank")

      error = assert_raises(RuntimeError) { DecisionsReader.new(db: db).load }
      assert_match(/op_1/, error.message)
    end
  end
end
