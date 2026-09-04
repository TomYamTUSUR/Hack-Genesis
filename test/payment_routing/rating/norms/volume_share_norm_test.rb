require_relative "../../../test_helper"

module PaymentRouting
  module Rating
    module Norms
      class VolumeShareNormTest < Minitest::Test
        include TestFactories

        def test_norm_follows_the_same_deviation_formula_as_count_share_but_on_volume
          p = provider(volume_share_pct: 50)
          pool = rating_pool(p => actuals(volume_share_actual: 25))

          norm = VolumeShareNorm.new.call(provider: p, operation: operation, pool: pool)

          assert_in_delta 0.75, norm, 0.0001
        end
      end
    end
  end
end
