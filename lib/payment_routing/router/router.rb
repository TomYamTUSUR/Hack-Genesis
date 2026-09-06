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
                     outcome_simulator: OutcomeSimulator.new, metrics_updater: MetricsUpdater.new, clock: -> { Time.now })
        @state = state
        @rated_payment_systems = rated_payment_systems
        @fallback_payment_system = fallback_payment_system
        @weight_calculator = Strategies::StrategyWeightCalculator.new(registry: strategy_registry)
        @active_strategies = active_strategies
        @hard_filter_engine = hard_filter_engine
        @provider_client = provider_client
        @outcome_simulator = outcome_simulator
        @metrics_updater = metrics_updater
        @clock = clock
      end

      def route_all(operations)
        operations.map { |operation| route(operation) }
      end

      def route(operation)
        @state.advance_to(operation.created_at || @clock.call)
        attempts = []
        explanation = { "eligibility" => [], "ranking" => [] }
        eligible = filter_eligible(operation, attempts, explanation)

        selected =
          if eligible.empty?
            fallback!(attempts, NO_ELIGIBLE_PROVIDER_REASON)
          else
            attempt_ranked_candidates(eligible, operation, attempts, explanation) || fallback!(attempts, ALL_PROVIDERS_UNAVAILABLE_REASON)
          end

        finalize(operation, selected, attempts, explanation)
      end

      private

      def rated_providers
        @rated_payment_systems.map { |name| @state.provider(name) }
      end

      def filter_eligible(operation, attempts, explanation)
        results = @hard_filter_engine.call_all(
          providers: rated_providers, operation: operation, actuals_by_provider: @state.actuals_by_provider
        )

        eligible = []
        results.each do |provider, result|
          explanation["eligibility"] << {
            "provider" => provider.payment_system, "is_eligible" => result.eligible?,
            "reasons" => result.reasons, "details" => result.details
          }
          if result.eligible?
            eligible << provider
          else
            attempts << Attempt.new(provider: provider.payment_system, decision: "skipped", reason: result.reasons.first,
                                    details: result.details.merge("reasons" => result.reasons))
          end
        end
        eligible
      end

      def attempt_ranked_candidates(eligible, operation, attempts, explanation)
        ranked = ranked_candidates(eligible, operation, explanation)

        ranked.each do |provider|
          @metrics_updater.start_attempt(state: @state, provider: provider, operation: operation)
          begin
            @provider_client.attempt(provider: provider, operation: operation)
          ensure
            @metrics_updater.finish_attempt(state: @state, provider: provider, operation: operation)
          end
          reason = ranked.size == 1 ? ONLY_ELIGIBLE_PROVIDER_REASON : HIGHEST_SCORE_REASON
          attempts << Attempt.new(provider: provider.payment_system, decision: "selected", reason: reason,
                                  dispatched_at: @state.time,
                                  details: explanation["ranking"].find { |row| row["provider"] == provider.payment_system })
          return provider
        rescue ProviderClient::UnavailableError
          attempts << Attempt.new(provider: provider.payment_system, decision: "skipped", reason: PROVIDER_UNAVAILABLE_REASON,
                                  dispatched_at: @state.time, details: { "result" => "provider unavailable during dispatch" })
        end
        nil
      end

      def ranked_candidates(eligible, operation, explanation)
        weights_and_gamma = @weight_calculator.call(active_keys: @active_strategies)
        calculator = Rating::ProviderScoreCalculator.new(weights: weights_and_gamma[:weights], gamma: weights_and_gamma[:gamma])
        ranked = calculator.rank(providers: eligible, actuals_by_provider: @state.actuals_by_provider, operation: operation)
        explanation.merge!(
          "active_strategies" => @active_strategies.map(&:to_s),
          "weights" => weights_and_gamma[:weights].transform_keys(&:to_s), "gamma" => weights_and_gamma[:gamma],
          "selection_policy" => "descending weighted score times load factor; ties follow rated_providers order",
          "ranking" => ranked.map { |row| { "provider" => row.provider.payment_system, "score" => row.score,
                                           "norms" => row.breakdown.transform_keys(&:to_s), "load_factor" => row.load_factor } }
        )
        ranked.map(&:provider)
      end

      def fallback!(attempts, reason)
        fallback_provider = @state.provider(@fallback_payment_system)
        attempts << Attempt.new(provider: fallback_provider.payment_system, decision: "selected", reason: reason)
        fallback_provider
      end

      def finalize(operation, selected, attempts, explanation)
        # Fallback keeps its existing selection policy; only accounting is shared.
        if selected.payment_system == @fallback_payment_system
          @state.record_request(selected.payment_system)
          attempts.last.dispatched_at = @state.time
          attempts.last.details = { "selection" => attempts.last.reason }
        end
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
          latency_sec: selected.avg_latency_sec || 0,
          explanation: explanation
        )
      end
    end
  end
end
