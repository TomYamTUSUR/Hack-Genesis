module PaymentRouting
  class RoutingRun
    Result = Struct.new(:processed, :decisions, keyword_init: true)

    def initialize(db:, database_path:, config:)
      @db = db
      @database_path = database_path
      @config = config
    end

    def call
      processed = false
      decisions = nil

      @db.transaction do
        Importers::BusinessParametersImporter.new(db: @db, business_parameters_file: @config.business_parameters_file).import

        rated_and_fallback = @config.rated_providers + [@config.fallback_provider]
        providers = ProviderRegistry.new(db: @db, rated_providers: rated_and_fallback).load
        raise "db/operations.db is empty or missing rated_providers/fallback_provider - run bin/import_data.rb" if providers.empty?

        actuals = HistoricalActualsProvider.new(db: @db).load
        operations = OperationQueueLoader.new(db: @db).load
        next if operations.empty?

        state = Router::RunState.new(providers: providers, actuals_by_provider: actuals)
        strategy_registry = Strategies::StrategyRegistry.new(strategies_file: @config.strategies_file)
        router = Router::Router.new(
          state: state,
          rated_payment_systems: @config.rated_providers,
          fallback_payment_system: @config.fallback_provider,
          strategy_registry: strategy_registry,
          active_strategies: @config.active_strategies
        )

        routed = router.route_all(operations)

        writer = RoutingAnalytics::DatabaseWriter.new(@database_path, db: @db)
        operations_by_id = operations.to_h { |operation| [operation.operation_id, { "operation_id" => operation.operation_id, "amount" => operation.amount, "bank" => operation.bank }] }

        Router::StateWriter.new(db: @db).write(state)
        writer.log_operations(
          operations: routed.map { |decision| operations_by_id.fetch(decision.operation_id) },
          decisions: routed.map(&:to_h)
        )
        writer.close

        decisions = DecisionsReader.new(db: @db).load
        processed = true
      end

      Result.new(processed: processed, decisions: decisions)
    end
  end
end
