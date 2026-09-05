require_relative "../../test_helper"

module PaymentRouting
  module Router
    class StateWriterTest < Minitest::Test
      include TestFactories

      def test_writes_runtime_fields_of_every_tracked_provider_back_to_the_db
        db = seeded_db
        state = RunState.new(
          providers: ProviderRegistry.new(db: db, rated_providers: %w[vipay payflow]).load,
          actuals_by_provider: {}
        )
        state.replace_provider(state.provider("vipay").with(in_progress_count: 9, in_progress_amount: 999_000, daily_approved_amount: 1_234_567))

        StateWriter.new(db: db).write(state)

        row = db[:providers].where(payment_system: "vipay").first
        assert_equal 9, row[:in_progress_count]
        assert_equal 999_000, row[:in_progress_amount]
        assert_equal 1_234_567, row[:daily_approved_amount]
      end
    end
  end
end
