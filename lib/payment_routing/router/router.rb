module PaymentRouting
  module Router
    # Оркестратор: для одной операции - hard-constraints (HardFilter) -> если
    # пул не пуст, ранжирование (Strategies+Rating) -> попытка кандидатов по
    # порядку рейтинга, с переходом к следующему при отказе (ProviderClient) ->
    # fallback на self-provider, если пул изначально пуст или все попытки
    # исчерпаны -> обновление рантайм-состояния (MetricsUpdater) для
    # следующей операции этой же очереди.
    class Router
      NO_ELIGIBLE_PROVIDER_REASON = "no_eligible_provider"
      ALL_PROVIDERS_UNAVAILABLE_REASON = "all_providers_unavailable"
      PROVIDER_UNAVAILABLE_REASON = "provider_unavailable"
      HIGHEST_SCORE_REASON = "highest_score"
      ONLY_ELIGIBLE_PROVIDER_REASON = "only_eligible_provider"

      def initialize(state:, rated_payment_systems:, fallback_payment_system:, strategy_registry:, active_strategies:,
                     hard_filter_engine: HardFilter::Engine.new, provider_client: ProviderClient.new,
                     outcome_simulator: OutcomeSimulator.new, metrics_updater: MetricsUpdater.new)
        @state = state
        @rated_payment_systems = rated_payment_systems
        @fallback_payment_system = fallback_payment_system
        @weight_calculator = Strategies::StrategyWeightCalculator.new(registry: strategy_registry)
        @active_strategies = active_strategies
        @hard_filter_engine = hard_filter_engine
        @provider_client = provider_client
        @outcome_simulator = outcome_simulator
        @metrics_updater = metrics_updater
      end

      def route_all(operations)
        operations.map { |operation| route(operation) }
      end

      def route(operation)
        attempts = []
        eligible = filter_eligible(operation, attempts)

        selected =
          if eligible.empty?
            fallback!(attempts, NO_ELIGIBLE_PROVIDER_REASON)
          else
            attempt_ranked_candidates(eligible, operation, attempts) || fallback!(attempts, ALL_PROVIDERS_UNAVAILABLE_REASON)
          end

        finalize(operation, selected, attempts)
      end

      private

      def rated_providers
        @rated_payment_systems.map { |name| @state.provider(name) }
      end

      def filter_eligible(operation, attempts)
        results = @hard_filter_engine.call_all(
          providers: rated_providers, operation: operation, actuals_by_provider: @state.actuals_by_provider
        )

        eligible = []
        results.each do |provider, result|
          if result.eligible?
            eligible << provider
          else
            # Одна попытка на провайдера (первая сработавшая причина), не одна
            # на причину: так требует формат ответа в ТЗ (один "reason" на
            # attempt) и первичный ключ eligible_providers (operation_id,
            # payment_system_id) - без него вторая причина того же провайдера
            # конфликтовала бы при записи через DatabaseWriter#log_operations.
            # Все причины при этом никуда не теряются на уровне HardFilter -
            # HardFilter::Result#reasons по-прежнему хранит их все, см. тесты.
            attempts << Attempt.new(provider: provider.payment_system, decision: "skipped", reason: result.reasons.first)
          end
        end
        eligible
      end

      def attempt_ranked_candidates(eligible, operation, attempts)
        ranked = ranked_candidates(eligible, operation)

        ranked.each do |provider|
          @provider_client.attempt(provider: provider, operation: operation)
          reason = ranked.size == 1 ? ONLY_ELIGIBLE_PROVIDER_REASON : HIGHEST_SCORE_REASON
          attempts << Attempt.new(provider: provider.payment_system, decision: "selected", reason: reason)
          return provider
        rescue ProviderClient::UnavailableError
          attempts << Attempt.new(provider: provider.payment_system, decision: "skipped", reason: PROVIDER_UNAVAILABLE_REASON)
        end
        nil
      end

      def ranked_candidates(eligible, operation)
        weights_and_gamma = @weight_calculator.call(active_keys: @active_strategies)
        calculator = Rating::ProviderScoreCalculator.new(weights: weights_and_gamma[:weights], gamma: weights_and_gamma[:gamma])
        calculator.rank(providers: eligible, actuals_by_provider: @state.actuals_by_provider, operation: operation).map(&:provider)
      end

      def fallback!(attempts, reason)
        fallback_provider = @state.provider(@fallback_payment_system)
        attempts << Attempt.new(provider: fallback_provider.payment_system, decision: "selected", reason: reason)
        fallback_provider
      end

      def finalize(operation, selected, attempts)
        simulated_result = @outcome_simulator.simulate(provider: selected, operation: operation)
        @metrics_updater.apply(
          state: @state, provider: selected, operation: operation, simulated_result: simulated_result,
          rated_payment_systems: @rated_payment_systems
        )

        Decision.new(
          operation_id: operation.operation_id,
          selected_provider: selected.payment_system,
          attempts: attempts,
          simulated_result: simulated_result,
          latency_sec: selected.avg_latency_sec || 0
        )
      end
    end
  end
end
