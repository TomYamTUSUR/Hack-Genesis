require_relative "../../test_helper"
require_relative "../../support/seeded_database"
require_relative "../../../lib/canonical_database_analytics"
require_relative "../../../lib/provider_minute_stats"
require "tmpdir"
require "open3"
require "rbconfig"

module PaymentRouting
  module Router
    class PersistenceRegressionsTest < Minitest::Test
      include TestFactories

      def setup
        @directory = Dir.mktmpdir("routing-regressions-")
        @path = SeededDatabase.seed(File.join(@directory, "operations.db"))
        @db = Db.connect(@path)
        @config = RoutingConfig.new
      end

      def teardown
        @db.disconnect
        FileUtils.remove_entry(@directory)
      end

      def cli(script, *arguments)
        Open3.capture3(RbConfig.ruby, File.join(PaymentRouting.root, script), *arguments)
      end

      def run_route
        output, error, status = cli("bin/route.rb", "--database", @path, "--output", File.join(@directory, "routing_decisions_test.json"))
        assert status.success?, "#{output}\n#{error}"
        output
      end

      def build_router(providers: nil, **options)
        providers ||= ProviderRegistry.new(db: @db, rated_providers: @config.rated_providers + [@config.fallback_provider]).load
        state = RunState.new(providers: providers, actuals_by_provider: HistoricalActualsProvider.new(db: @db).load)
        router = Router.new(
          state: state, rated_payment_systems: providers.map(&:payment_system) - [@config.fallback_provider],
          fallback_payment_system: @config.fallback_provider,
          strategy_registry: Strategies::StrategyRegistry.new(strategies_file: @config.strategies_file),
          active_strategies: [:priority], **options
        )
        [router, state]
      end

      def save(operations, decisions, state)
        @db.transaction do
          StateWriter.new(db: @db).write(state)
          RoutingAnalytics::DatabaseWriter.new(@path, db: @db).log_operations(
            operations: operations.map(&:to_h), decisions: decisions.map(&:to_h)
          )
        end
      end

      def test_cli_is_idempotent_and_processes_only_new_operations
        before = @db[:providers].sum(:daily_approved_amount)
        workload = @db[:providers].order(:payment_system).select_map([:in_progress_count, :in_progress_amount])
        total = @db[:operations_queue].sum(:amount)
        run_route
        assert_equal before + total, @db[:providers].sum(:daily_approved_amount)
        assert_equal workload, @db[:providers].order(:payment_system).select_map([:in_progress_count, :in_progress_amount])
        saved = DecisionsReader.new(db: @db).load
        providers = @db[:providers].order(:payment_system).all

        assert_match(/Нет необработанных/, run_route)
        assert_equal providers, @db[:providers].order(:payment_system).all
        assert_equal saved, DecisionsReader.new(db: @db).load
        assert_empty OperationQueueLoader.new(db: @db).load

        @db[:operations_queue].insert(operation_id: "new", created_at: "2026-07-30T11:00:00+03:00", amount: 1000, bank: "sberbank")
        run_route
        assert_equal 11, @db[:routing_decisions].count
        assert_equal before + total + 1000, @db[:providers].sum(:daily_approved_amount)
        assert_equal saved, DecisionsReader.new(db: @db).load.reject { |row| row["operation_id"] == "new" }
      end

      def test_queue_excludes_history_and_decisions_and_orders_absolute_timestamps
        id = @db[:providers].get(:payment_system_id)
        @db[:operations_history].insert(operation_id: "op_101", created_at: "2026-07-30T09:05:00+03:00",
                                       amount: 15000, bank: "sberbank", payment_system_id: id, status: "approved")
        @db[:routing_decisions].insert(operation_id: "op_102", selected_payment_system_id: id,
                                       simulated_result: "approved", latency_sec: 1, created_at: Time.now)
        @db[:operations_queue].where(operation_id: "op_103").update(created_at: "2026-07-30T11:00:00+07:00")
        @db[:operations_queue].where(operation_id: "op_104").update(created_at: "2026-07-30T08:00:00+03:00")

        operations = OperationQueueLoader.new(db: @db).load
        assert_equal %w[op_103 op_104], operations.first(2).map(&:operation_id)
        refute_includes operations.map(&:operation_id), "op_101"
        refute_includes operations.map(&:operation_id), "op_102"
      end

      def test_cli_rolls_back_state_and_history_when_either_write_fails
        before = @db[:providers].order(:payment_system).all
        [
          "CREATE TRIGGER reject_write BEFORE INSERT ON routing_decisions BEGIN SELECT RAISE(ABORT, 'decision failure'); END",
          "CREATE TRIGGER reject_write BEFORE UPDATE ON providers WHEN NEW.payment_system = 'vipay' BEGIN SELECT RAISE(ABORT, 'provider failure'); END"
        ].each do |trigger|
          @db.run(trigger)
          _, _, status = cli("bin/route.rb", "--database", @path)
          refute status.success?
          assert_equal before, @db[:providers].order(:payment_system).all
          assert_equal 0, @db[:routing_decisions].count
          assert_equal 0, @db[:routing_attempts].count
          assert_equal 100, @db[:operations_history].count
          @db.run("DROP TRIGGER reject_write")
        end
      end

      def test_state_writer_itself_rolls_back_all_providers
        before = @db[:providers].order(:payment_system).all
        _, state = build_router
        state.providers.each { |p| state.replace_provider(p.with(daily_approved_amount: p.daily_approved_amount + 1000)) }
        @db.run("CREATE TRIGGER reject_state BEFORE UPDATE ON providers WHEN NEW.payment_system = 'vipay' BEGIN SELECT RAISE(ABORT, 'failure'); END")

        assert_raises(Sequel::DatabaseError) { StateWriter.new(db: @db).write(state) }
        assert_equal before, @db[:providers].order(:payment_system).all
      end

      def test_minute_statistics_with_missing_conversion_still_allows_routing
        ProviderMinuteStats.new(database: @path, at: Time.iso8601("2026-07-29T08:01:00+03:00")).run
        assert_equal 1, @db[:providers].where(payment_system: "vipay").get(:conversion_24h)
        assert_nil @db[:providers].where(payment_system: "payflow").get(:conversion_24h)

        run_route
        assert_equal 10, @db[:routing_decisions].count
      end

      def test_history_preserves_event_time_and_brand_and_artifacts_pass_validation
        timestamp = Time.iso8601("2026-07-30T09:05:00.123456+03:00")
        @db[:operations_queue].where(operation_id: "op_101").update(created_at: timestamp.iso8601(6), card_brand: "mir")
        run_route
        history = @db[:operations_history].where(operation_id: "op_101").first
        assert_equal timestamp, history[:created_at]
        assert_equal "mir", history[:card_brand]

        decisions = File.join(@directory, "decisions.json")
        report = File.join(@directory, "report.json")
        [
          ["bin/build_decisions.rb", "--database", @path, "--output", decisions],
          ["scripts/validate_10.rb", decisions],
          ["bin/build_report.rb", "--database", @path, "--output", report]
        ].each do |script, *args|
          stdout, stderr, status = cli(script, *args)
          assert status.success?, "#{stdout}\n#{stderr}"
        end
        reconstructed = JSON.parse(File.read(decisions))
        assert reconstructed.flat_map { |row| row["attempts"] }.all? { |attempt| attempt["details"] }
        explained = JSON.parse(File.read(report)).fetch("routing_explanations")
        assert_equal reconstructed.first["explanation"], explained.fetch(reconstructed.first["operation_id"])
      end

      def test_dispatch_log_preserves_eligibility_and_drives_rpm_and_cascade_analytics
        @db[:operations_history].delete
        providers = %w[vipay payflow quickpay spacepayments].each_with_index.map do |name, i|
          provider(payment_system: name, priority: i + 1, requests_per_minute_limit: name == "vipay" ? 1 : nil)
        end
        calls = []
        client = Object.new
        client.define_singleton_method(:attempt) do |provider:, operation:|
          calls << provider.payment_system
          raise ProviderClient::UnavailableError if provider.payment_system == "vipay"
        end
        router, state = build_router(providers: providers, provider_client: client)
        op = OperationQueueLoader.new(db: @db).load.first
        decision = router.route(op)
        save([op], [decision], state)

        stored = @db[:routing_decisions].where(operation_id: op.operation_id).first
        assert_equal decision.explanation, JSON.parse(stored[:explanation])
        stored_attempts = DecisionsReader.new(db: @db).send(:attempts_by_operation_id).fetch(op.operation_id)
        assert_equal decision.attempts.map(&:to_h), stored_attempts
        eligibility = @db[:eligible_providers].join(:providers, payment_system_id: :payment_system_id).to_hash(:payment_system, :is_eligible)
        assert_equal({ "vipay" => true, "payflow" => true, "quickpay" => true }, eligibility)

        at = op.created_at + 30
        reloaded = HistoricalActualsProvider.new(db: @db).load(at: at)
        assert_equal 1, reloaded["vipay"].rpm_used
        assert_equal 1, reloaded["payflow"].rpm_used
        assert_equal 0, reloaded["quickpay"].rpm_used
        next_router, next_state = build_router(providers: state.providers, provider_client: client)
        next_op = operation(operation_id: "next", created_at: at, amount: 1000, bank: "sberbank")
        next_router.route(next_op)
        assert_equal 1, calls.count("vipay")
        assert_equal 1, next_state.actuals("vipay").rpm_used
        assert_equal 0, HistoricalActualsProvider.new(db: @db).load(at: op.created_at + 60)["vipay"].rpm_used

        analytics = RoutingAnalytics::CanonicalDatabaseAnalytics.new(@path)
        cascades = analytics.report.fetch("attempt_cascades")
        assert_equal 0, cascades["first_choice_operations"]
        assert_equal 1, cascades["fallback_operations"]
        assert_equal 0, cascades["first_attempt_success_pct"]
      ensure
        analytics&.close
      end

      def test_shares_with_fallback_are_consistent_after_save_and_reload
        @db[:operations_history].delete
        ids = @db[:providers].to_hash(:payment_system, :payment_system_id)
        (%w[vipay payflow] + ["spacepayments"] * 8).each_with_index do |name, i|
          @db[:operations_history].insert(operation_id: "historical_#{i}", created_at: "2026-07-29T12:00:00+03:00",
                                         amount: 1000, bank: "sberbank", payment_system_id: ids[name], status: "approved")
        end
        providers = %w[vipay payflow quickpay spacepayments].each_with_index.map { |name, i| provider(payment_system: name, priority: i + 1) }
        router, state = build_router(providers: providers)
        op = operation(operation_id: "op_101", amount: 1000, bank: "sberbank", created_at: "2026-07-30T09:05:00+03:00")
        assert_in_delta 10, state.actuals("vipay").count_share_actual
        decision = router.route(op)
        save([op], [decision], state)
        loaded = HistoricalActualsProvider.new(db: @db).load(at: op.created_at)

        assert_in_delta 100, state.actuals_by_provider.values.sum(&:count_share_actual)
        assert_in_delta 200.0 / 11, state.actuals("vipay").count_share_actual
        state.actuals_by_provider.each do |name, values|
          assert_in_delta values.count_share_actual, loaded[name].count_share_actual
          assert_in_delta values.volume_share_actual, loaded[name].volume_share_actual
        end
      end

      def test_daily_turnover_uses_snapshot_and_stays_consistent_after_day_rollover
        actuals = HistoricalActualsProvider.new(db: @db).load
        assert_equal 2_900_000, actuals["payflow"].turnover_actual
        run_route
        @db[:operations_queue].insert(operation_id: "next_day", created_at: "2026-07-31T00:00:00+03:00", amount: 1000, bank: "sberbank")
        run_route

        assert_equal 1000, @db[:providers].sum(:daily_approved_amount)
        assert_equal ["2026-07-31"], @db[:providers].select_map(:daily_approved_date).uniq
        reloaded = HistoricalActualsProvider.new(db: @db).load
        assert_equal 1000, reloaded.values.sum(&:turnover_actual)
        @db[:providers].each { |row| assert_equal row[:daily_approved_amount], reloaded.fetch(row[:payment_system]).turnover_actual }
      end

      def test_additive_schema_upgrade_keeps_old_data_and_is_idempotent
        { providers: %i[daily_approved_date daily_utc_offset], routing_decisions: [:explanation],
          routing_attempts: %i[details dispatched_at] }.each do |table, columns|
          columns.each { |column| @db.alter_table(table) { drop_column column } }
        end
        before = @db[:providers].order(:payment_system).all
        Db.upgrade_schema!(@db)
        Db.upgrade_schema!(@db)

        assert_equal before, @db[:providers].order(:payment_system).all.map { |row| row.reject { |key, _| %i[daily_approved_date daily_utc_offset].include?(key) } }
        run_route
        assert_equal 10, @db[:routing_decisions].count
      end
    end
  end
end
