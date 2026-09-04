require_relative "../../../test_helper"

module PaymentRouting
  module Rating
    module Norms
      class RangeFitNormTest < Minitest::Test
        include TestFactories

        def setup
          @norm = RangeFitNorm.new
          @provider = provider(preferred_range: AmountRange.new(min: 500, max: 50_000))
          @pool = rating_pool(@provider => actuals)
        end

        def test_amount_at_the_middle_of_the_range_gets_the_maximum_norm
          op = operation(amount: 25_250)

          assert_in_delta 1.0, @norm.call(provider: @provider, operation: op, pool: @pool), 0.0001
        end

        def test_amount_at_the_edge_of_the_range_gets_zero
          op = operation(amount: 500)

          assert_in_delta 0.0, @norm.call(provider: @provider, operation: op, pool: @pool), 0.0001
        end

        def test_amount_outside_the_range_is_clipped_to_zero
          op = operation(amount: 90_000)

          assert_equal 0.0, @norm.call(provider: @provider, operation: op, pool: @pool)
        end
      end
    end
  end
end
