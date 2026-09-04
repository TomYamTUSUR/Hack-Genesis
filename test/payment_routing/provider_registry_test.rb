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
      vipay = @registry.load.find { |p| p.payment_system == "vipay" }
      row = @db[:providers].where(payment_system: "vipay").first

      assert_nil row[:preferred_range_min]
      assert_nil vipay.preferred_range
    end

    def test_preferred_range_is_used_as_is_when_set_without_touching_hard_limits
      @db[:providers].where(payment_system: "vipay").update(preferred_range_min: 60_000, preferred_range_max: 90_000)

      vipay = @registry.load.find { |p| p.payment_system == "vipay" }

      assert_equal 60_000, vipay.preferred_range.min
      assert_equal 90_000, vipay.preferred_range.max
    end
  end
end
