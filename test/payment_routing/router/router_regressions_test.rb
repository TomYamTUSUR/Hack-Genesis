require_relative "../../test_helper"

module PaymentRouting
  module Router
    class RouterRegressionsTest < Minitest::Test
      include TestFactories

      def setup
        @at = Time.iso8601("2026-07-30T09:05:00+03:00")
        @primary = provider(payment_system: "vipay", priority: 1)
        @other = provider(payment_system: "payflow", priority: 2)
        @fallback = provider(payment_system: "spacepayments", priority: 99)
      end

      def build(providers = [@primary, @other, @fallback], active: [:priority], actual_values: nil, **options)
        state = RunState.new(providers: providers, actuals_by_provider: actual_values ||
          providers.to_h { |p| [p.payment_system, actuals(turnover_actual: p.daily_approved_amount)] })
        router = Router.new(
          state: state, rated_payment_systems: providers.map(&:payment_system) - ["spacepayments"],
          fallback_payment_system: "spacepayments",
          strategy_registry: Strategies::StrategyRegistry.new(strategies_file: RoutingConfig.new.strategies_file),
          active_strategies: active, **options
        )
        [router, state]
      end

      def payout(id, at: @at, amount: 1000)
        operation(operation_id: id, amount: amount, bank: "sberbank", created_at: at)
      end

      def test_rpm_is_consumed_and_expires_at_the_exact_window_boundary
        router, state = build([@primary.with(requests_per_minute_limit: 1), @fallback])

        assert_equal "vipay", router.route(payout("first")).selected_provider
        assert_equal 1, state.actuals("vipay").rpm_used
        assert_equal "spacepayments", router.route(payout("second", at: @at + Rational(59999, 1000))).selected_provider
        assert_equal "vipay", router.route(payout("third", at: @at + 60)).selected_provider
        assert_equal 1, state.actuals("vipay").rpm_used
      end

      def test_failed_dispatch_consumes_rpm_and_releases_its_reservation
        calls = []
        client = Object.new
        client.define_singleton_method(:attempt) do |provider:, operation:|
          calls << provider.payment_system
          raise ProviderClient::UnavailableError if provider.payment_system == "vipay"
        end
        router, state = build([@primary.with(requests_per_minute_limit: 1), @other, @fallback], provider_client: client)

        assert_equal "payflow", router.route(payout("first")).selected_provider
        decision = router.route(payout("second", at: @at + 1))
        assert_equal "payflow", decision.selected_provider
        assert_equal 1, calls.count("vipay")
        assert_equal "rate_limit_exceeded", decision.attempts.find { |a| a.provider == "vipay" }.reason
        assert_equal 0, state.provider("vipay").in_progress_count
        assert_equal 0, state.provider("vipay").in_progress_amount
      end

      def test_terminal_outcomes_preserve_existing_workload
        %w[approved rejected expired].each do |outcome|
          simulator = Object.new
          simulator.define_singleton_method(:simulate) { |**| outcome }
          router, state = build([
            @primary.with(in_progress_count: 2, in_progress_amount: 5000, in_progress_count_limit: 3), @fallback
          ], outcome_simulator: simulator)

          2.times do |index|
            decision = router.route(payout("operation_#{index}"))
            assert_equal "vipay", decision.selected_provider
            assert_equal outcome, decision.simulated_result
            assert_equal 2, state.provider("vipay").in_progress_count
            assert_equal 5000, state.provider("vipay").in_progress_amount
          end
          assert_equal(outcome == "approved" ? 2000 : 0, state.provider("vipay").daily_approved_amount)
        end
      end

      def test_reservation_is_visible_during_dispatch_and_released_on_unexpected_error
        client = Object.new
        router, state = build([@primary, @fallback], provider_client: client)
        observed = []
        client.define_singleton_method(:attempt) do |**|
          observed << [state.provider("vipay").in_progress_count, state.provider("vipay").in_progress_amount]
          raise IOError, "dispatch failed"
        end

        assert_raises(IOError) { router.route(payout("first")) }
        assert_equal [[1, 1000]], observed
        assert_equal 0, state.provider("vipay").in_progress_count
        assert_equal 0, state.provider("vipay").in_progress_amount
      end

      def test_missing_conversion_does_not_crash_any_supported_pool
        [[0.9, nil], [nil, nil], [nil]].each do |conversions|
          providers = conversions.each_with_index.map do |conversion, i|
            provider(payment_system: "provider_#{i}", priority: i + 1, conversion_24h: conversion)
          end
          [[:priority], [:priority, :turnover], [:conversion]].each do |active|
            router, = build(providers + [@fallback], active: active)
            decision = router.route(payout("conversion"))
            assert_includes providers.map(&:payment_system), decision.selected_provider
            assert decision.explanation.fetch("ranking").all? { |row| row["score"].finite? }
          end
        end
      end

      def test_daily_snapshot_resets_at_midnight_in_its_own_timezone
        p = @primary.with(daily_approved_amount: 5000, daily_amount_limit: 5000, daily_turnover_max: 5000,
                          daily_approved_date: "2026-07-30", daily_utc_offset: 3 * 3600)
        router, state = build([p, @fallback])
        before_midnight = Time.iso8601("2026-07-30T20:59:59Z")
        assert_equal "spacepayments", router.route(payout("before", at: before_midnight)).selected_provider
        assert_equal "vipay", router.route(payout("after", at: before_midnight + 1)).selected_provider
        assert_equal "2026-07-31", state.provider("vipay").daily_approved_date
        assert_equal 1000, state.provider("vipay").daily_approved_amount
        assert_equal 1000, state.actuals("vipay").turnover_actual
      end

      def test_unfulfilled_turnover_obligation_outranks_no_obligation
        obligated = @primary.with(daily_turnover_min: 2_000_000, daily_approved_amount: 1_500_000)
        unbound = @other.with(priority: 1)
        router, = build([obligated, unbound, @fallback], active: [:turnover])

        assert_equal "vipay", router.route(payout("turnover")).selected_provider
      end

      def test_filter_details_and_ranking_cover_unattempted_candidates
        blocked = provider(payment_system: "blocked", status: "paused", limit_amount_max: 500)
        router, = build([@primary, @other, blocked, @fallback], active: [:priority, :conversion])
        decision = router.route(payout("explained"))

        assert_equal %w[vipay payflow], decision.explanation.fetch("ranking").map { |row| row["provider"] }
        assert_equal %w[priority conversion], decision.explanation.fetch("active_strategies")
        assert_in_delta 1, decision.explanation.fetch("weights").values.sum
        skip = decision.attempts.find { |a| a.provider == "blocked" }
        assert_equal %w[status_not_active amount_exceeds_limit], skip.details.fetch("reasons")
        assert_equal 1000, skip.details.dig("operation", "amount")
        assert_equal 500, skip.details.dig("provider", "limit_amount_max")
        assert_nil skip.dispatched_at
        assert_equal @at, decision.attempts.find { |a| a.decision == "selected" }.dispatched_at
      end

      def test_fallback_selection_remains_unchanged_as_requested
        router, = build([@primary.with(status: "paused"), @fallback.with(status: "paused", available_requisites: 0)])
        decision = router.route(payout("fallback"))

        assert_equal "spacepayments", decision.selected_provider
        assert_equal "approved", decision.simulated_result
        refute decision.explanation["eligibility"].any? { |check| check["provider"] == "spacepayments" }
      end
    end
  end
end
