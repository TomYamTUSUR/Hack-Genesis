require_relative "../test_helper"

module PaymentRouting
  class HistoricalActualsProviderTest < Minitest::Test
    include TestFactories

    def setup
      @db = seeded_db
      @actuals_by_provider = HistoricalActualsProvider.new(db: @db).load
    end

    def test_computes_shares_only_from_approved_operations_for_every_rated_provider
      %w[vipay payflow quickpay].each { |payment_system| assert @actuals_by_provider.key?(payment_system) }
    end

    def test_a_provider_with_zero_approved_operations_still_gets_a_neutral_entry
      quickpay_id = @db[:providers].where(payment_system: "quickpay").first[:payment_system_id]
      @db[:operations_history].where(payment_system_id: quickpay_id).delete

      actuals = HistoricalActualsProvider.new(db: @db).load

      assert actuals.key?("quickpay")
      assert_equal 0.0, actuals["quickpay"].count_share_actual
      assert_equal 0.0, actuals["quickpay"].turnover_actual
    end

    def test_count_and_volume_shares_across_providers_sum_to_roughly_a_hundred_percent
      assert_in_delta 100.0, @actuals_by_provider.values.sum(&:count_share_actual), 0.01
      assert_in_delta 100.0, @actuals_by_provider.values.sum(&:volume_share_actual), 0.01
    end

    def test_rpm_used_defaults_to_zero_no_runtime_counter_exists_yet
      assert_equal 0.0, @actuals_by_provider["vipay"].rpm_used
    end
  end
end
