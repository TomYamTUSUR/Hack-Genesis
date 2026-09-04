require_relative "../../../test_helper"

module PaymentRouting
  module Rating
    module Norms
      class TurnoverNormTest < Minitest::Test
        include TestFactories

        def test_norm_rises_above_half_when_minimum_turnover_is_not_yet_reached
          p = provider(daily_turnover_min: 2_000_000)
          pool = rating_pool(p => actuals(turnover_actual: 1_500_000))

          norm = TurnoverNorm.new.call(provider: p, operation: operation, pool: pool)

          assert_in_delta 0.625, norm, 0.0001
        end

        def test_provider_without_a_turnover_obligation_is_neither_boosted_nor_penalized
          p = provider(daily_turnover_min: nil)
          pool = rating_pool(p => actuals(turnover_actual: 0))

          assert_equal 1.0, TurnoverNorm.new.call(provider: p, operation: operation, pool: pool)
        end
      end
    end
  end
end
