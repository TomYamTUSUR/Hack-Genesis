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

    def test_rpm_used_counts_every_status_within_the_last_minute_of_history
      @db[:operations_history].delete
      vipay_id = @db[:providers].where(payment_system: "vipay").first[:payment_system_id]
      payflow_id = @db[:providers].where(payment_system: "payflow").first[:payment_system_id]

      # Последняя операция в истории задаёт "текущее" время окна - 12:00:00.
      insert_history(id: "op_1", provider_id: vipay_id, at: "2026-07-30T11:59:10+03:00", status: "approved")
      insert_history(id: "op_2", provider_id: vipay_id, at: "2026-07-30T11:59:30+03:00", status: "rejected")
      insert_history(id: "op_3", provider_id: payflow_id, at: "2026-07-30T11:59:50+03:00", status: "expired")
      # За пределами минутного окна (ровно 61 секунда до последней операции) - не должна учитываться.
      insert_history(id: "op_old", provider_id: vipay_id, at: "2026-07-30T11:58:59+03:00", status: "approved")
      insert_history(id: "op_latest", provider_id: payflow_id, at: "2026-07-30T12:00:00+03:00", status: "approved")

      actuals = HistoricalActualsProvider.new(db: @db).load

      assert_equal 2, actuals["vipay"].rpm_used
      assert_equal 2, actuals["payflow"].rpm_used
      assert_equal 0, actuals["quickpay"].rpm_used
    end

    private

    def insert_history(id:, provider_id:, at:, status:)
      @db[:operations_history].insert(
        operation_id: id, created_at: at, amount: 1000, bank: "sberbank",
        payment_system_id: provider_id, status: status, latency_sec: 30
      )
    end
  end
end
