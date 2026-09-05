require_relative "../../test_helper"

module PaymentRouting
  module Router
    # Прогоняет Router по всем 10 реальным операциям очереди и сверяет с
    # data/reference_decisions.json - в отличие от router_test.rb (синтетика),
    # здесь честные данные из БД и настоящий HardFilter/Rating/Strategies.
    class RouterReferenceDataTest < Minitest::Test
      include TestFactories

      def setup
        @db = seeded_db
        @config = RoutingConfig.new
        all_names = @config.rated_providers + [@config.fallback_provider]

        providers = ProviderRegistry.new(db: @db, rated_providers: all_names).load
        actuals = HistoricalActualsProvider.new(db: @db).load
        @operations = OperationQueueLoader.new(db: @db).load

        state = RunState.new(providers: providers, actuals_by_provider: actuals)
        registry = Strategies::StrategyRegistry.new(strategies_file: @config.strategies_file)
        @router = Router.new(
          state: state, rated_payment_systems: @config.rated_providers, fallback_payment_system: @config.fallback_provider,
          strategy_registry: registry, active_strategies: @config.active_strategies
        )

        @reference = JSON.parse(File.read(File.join(PaymentRouting.root, "data", "reference_decisions.json")))
        @decisions_by_operation_id = @router.route_all(@operations).to_h { |decision| [decision.operation_id, decision] }
      end

      def test_covers_every_operation_in_the_queue
        assert_equal @operations.map(&:operation_id).sort, @decisions_by_operation_id.keys.sort
      end

      def test_matches_every_deterministic_case
        @reference.fetch("deterministic_cases").each do |case_|
          decision = @decisions_by_operation_id.fetch(case_["operation_id"])
          assert_equal case_["required_provider"], decision.selected_provider,
            "#{case_['operation_id']}: #{case_['reason']}"
        end
      end

      def test_selected_provider_is_always_among_the_eligible_ones
        @reference.fetch("eligible_providers").each do |operation_id, eligible|
          decision = @decisions_by_operation_id.fetch(operation_id)
          # spacepayments - fallback, допустим только если эталон не даёт ни
          # одного подходящего провайдера (в текущих 10 операциях такого нет).
          assert_includes eligible, decision.selected_provider
        end
      end

      def test_all_decisions_are_approved_in_v1
        assert @decisions_by_operation_id.values.all? { |decision| decision.simulated_result == "approved" }
      end
    end
  end
end
