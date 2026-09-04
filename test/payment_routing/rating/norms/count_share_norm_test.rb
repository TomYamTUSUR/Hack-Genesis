require_relative "../../../test_helper"

module PaymentRouting
  module Rating
    module Norms
      class CountShareNormTest < Minitest::Test
        include TestFactories

        def setup
          @norm = CountShareNorm.new
        end

        def test_norm_rises_above_half_when_provider_is_under_its_target_share
          p = provider(traffic_percentage: 40)
          pool = rating_pool(p => actuals(count_share_actual: 20))

          assert_in_delta 0.75, @norm.call(provider: p, operation: operation, pool: pool), 0.0001
        end

        def test_norm_is_half_exactly_at_target
          p = provider(traffic_percentage: 40)
          pool = rating_pool(p => actuals(count_share_actual: 40))

          assert_in_delta 0.5, @norm.call(provider: p, operation: operation, pool: pool), 0.0001
        end

        def test_norm_is_clipped_to_zero_far_above_target
          p = provider(traffic_percentage: 40)
          pool = rating_pool(p => actuals(count_share_actual: 90))

          assert_equal 0.0, @norm.call(provider: p, operation: operation, pool: pool)
        end
      end
    end
  end
end
