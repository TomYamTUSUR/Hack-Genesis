require_relative "../test_helper"

module PaymentRouting
  class ProviderRegistryTest < Minitest::Test
    include TestFactories

    def setup
      @db = seeded_db
      @registry = ProviderRegistry.new(db: @db, rated_providers: %w[vipay payflow])
    end

    def test_loads_only_the_configured_rated_providers
      providers = @registry.load

      assert_equal %w[vipay payflow].sort, providers.map(&:payment_system).sort
    end

    def test_preferred_range_is_nil_when_not_set
      @db[:providers].where(payment_system: "vipay").update(preferred_range_min: nil, preferred_range_max: nil)

      vipay = @registry.load.find { |p| p.payment_system == "vipay" }

      assert_nil vipay.preferred_range
    end

    def test_preferred_range_is_used_as_is_when_set_without_touching_hard_limits
      @db[:providers].where(payment_system: "vipay").update(preferred_range_min: 60_000, preferred_range_max: 90_000)

      vipay = @registry.load.find { |p| p.payment_system == "vipay" }

      assert_equal 60_000, vipay.preferred_range.min
      assert_equal 90_000, vipay.preferred_range.max
    end

    def test_raises_when_daily_turnover_min_is_negative
      @db[:providers].where(payment_system: "vipay").update(daily_turnover_min: -1)

      error = assert_raises(RuntimeError) { @registry.load }
      assert_match(/daily_turnover_min \(-1\) не может быть отрицательным/, error.message)
    end

    def test_raises_when_daily_turnover_max_exceeds_daily_amount_limit
      daily_amount_limit = @db[:providers].where(payment_system: "vipay").first[:daily_amount_limit]
      @db[:providers].where(payment_system: "vipay").update(daily_turnover_max: daily_amount_limit + 1)

      error = assert_raises(RuntimeError) { @registry.load }
      assert_match(/daily_turnover_max .* не может превышать daily_amount_limit/, error.message)
    end

    def test_raises_when_daily_turnover_min_is_greater_than_daily_turnover_max
      @db[:providers].where(payment_system: "vipay").update(daily_turnover_min: 2_000_000, daily_turnover_max: 1_000_000)

      error = assert_raises(RuntimeError) { @registry.load }
      assert_match(/daily_turnover_min \(2000000\) не может быть больше daily_turnover_max \(1000000\)/, error.message)
    end

    def test_does_not_raise_when_turnover_bounds_are_consistent
      daily_amount_limit = @db[:providers].where(payment_system: "vipay").first[:daily_amount_limit]
      @db[:providers].where(payment_system: "vipay").update(daily_turnover_min: 1_000_000, daily_turnover_max: daily_amount_limit)

      vipay = @registry.load.find { |p| p.payment_system == "vipay" }

      assert_equal 1_000_000, vipay.daily_turnover_min
    end
  end
end
