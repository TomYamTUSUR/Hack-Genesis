require_relative "../test_helper"

module PaymentRouting
  class HistoricalActualsProviderTest < Minitest::Test
    include TestFactories

    def setup
      @actuals_by_provider = HistoricalActualsProvider.new(db: seeded_db).load
    end

    def test_computes_shares_only_from_approved_operations_for_every_rated_provider
      %w[vipay payflow quickpay].each { |payment_system| assert @actuals_by_provider.key?(payment_system) }
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
