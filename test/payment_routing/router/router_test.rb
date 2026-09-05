require_relative "../../test_helper"

module PaymentRouting
  module Router
    # Провайдер-заглушка для проверки перехода к следующему кандидату при
    # отказе: бросает UnavailableError для перечисленных payment_system,
    # остальным отвечает как обычно (см. ProviderClient).
    class FailingProviderClient
      def initialize(fails_for:)
        @fails_for = fails_for
      end

      def attempt(provider:, operation:)
        raise ProviderClient::UnavailableError if @fails_for.include?(provider.payment_system)
      end
    end

    class RouterTest < Minitest::Test
      include TestFactories

      def setup
        @vipay = provider(payment_system: "vipay", priority: 1)
        @payflow = provider(payment_system: "payflow", priority: 2)
        @fallback = provider(payment_system: "spacepayments", priority: 99)
        @actuals_by_provider = { "vipay" => actuals, "payflow" => actuals, "spacepayments" => actuals }
        @operation = operation
      end

      def test_ranks_and_selects_the_top_eligible_candidate
        router = build_router(providers: [@vipay, @payflow, @fallback])

        decision = router.route(@operation)

        assert_equal "vipay", decision.selected_provider
        assert_equal "approved", decision.simulated_result
        selected_attempt = decision.attempts.find { |a| a.decision == "selected" }
        assert_equal "highest_score", selected_attempt.reason
      end

      def test_falls_back_to_self_provider_when_hard_constraints_exclude_everyone
        blocked_vipay = @vipay.with(status: "paused")
        blocked_payflow = @payflow.with(status: "paused")
        router = build_router(providers: [blocked_vipay, blocked_payflow, @fallback])

        decision = router.route(@operation)

        assert_equal "spacepayments", decision.selected_provider
        fallback_attempt = decision.attempts.find { |a| a.decision == "selected" }
        assert_equal "no_eligible_provider", fallback_attempt.reason
        skipped = decision.attempts.select { |a| a.decision == "skipped" }
        assert_equal %w[vipay payflow], skipped.map(&:provider)
        assert_equal %w[status_not_active status_not_active], skipped.map(&:reason)
      end

      def test_moves_to_the_next_candidate_when_the_top_one_is_unavailable
        client = FailingProviderClient.new(fails_for: ["vipay"])
        router = build_router(providers: [@vipay, @payflow, @fallback], provider_client: client)

        decision = router.route(@operation)

        assert_equal "payflow", decision.selected_provider
        assert_equal(
          [
            ["vipay", "skipped", "provider_unavailable"],
            ["payflow", "selected", "highest_score"]
          ],
          decision.attempts.map { |a| [a.provider, a.decision, a.reason] }
        )
      end

      def test_falls_back_to_self_provider_when_every_ranked_candidate_is_unavailable
        client = FailingProviderClient.new(fails_for: %w[vipay payflow])
        router = build_router(providers: [@vipay, @payflow, @fallback], provider_client: client)

        decision = router.route(@operation)

        assert_equal "spacepayments", decision.selected_provider
        fallback_attempt = decision.attempts.find { |a| a.decision == "selected" }
        assert_equal "all_providers_unavailable", fallback_attempt.reason
      end

      def test_updates_run_state_for_the_selected_provider_after_routing
        router = build_router(providers: [@vipay, @payflow, @fallback])
        state = router.instance_variable_get(:@state)
        before = state.provider("vipay").in_progress_count

        router.route(@operation)

        assert_equal before + 1, state.provider("vipay").in_progress_count
      end

      private

      def build_router(providers:, provider_client: ProviderClient.new)
        state = RunState.new(providers: providers, actuals_by_provider: @actuals_by_provider)
        registry = Strategies::StrategyRegistry.new(strategies_file: RoutingConfig.new.strategies_file)
        Router.new(
          state: state, rated_payment_systems: %w[vipay payflow], fallback_payment_system: "spacepayments",
          strategy_registry: registry, active_strategies: [:priority], provider_client: provider_client
        )
      end
    end
  end
end
