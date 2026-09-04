require_relative "../../../test_helper"

module PaymentRouting
  module Rating
    module Norms
      class IntensityNormTest < Minitest::Test
        include TestFactories

        def test_norm_is_the_complement_of_rpm_utilization
          p = provider(requests_per_minute_limit: 15)
          pool = rating_pool(p => actuals(rpm_used: 5))

          norm = IntensityNorm.new.call(provider: p, operation: operation, pool: pool)

          assert_in_delta 0.6667, norm, 0.001
        end

        def test_provider_at_its_rpm_limit_gets_zero
          p = provider(requests_per_minute_limit: 15)
          pool = rating_pool(p => actuals(rpm_used: 15))

          assert_equal 0.0, IntensityNorm.new.call(provider: p, operation: operation, pool: pool)
        end

        def test_norm_ignores_in_progress_load_unlike_the_universal_load_factor
          # По ключевому параметру стратегии (rpm) провайдер почти свободен,
          # хотя in_progress почти на пределе - в отличие от LoadFactor, эта
          # норма не должна на это реагировать (см. LoadFactorCalculator#utilization).
          p = provider(requests_per_minute_limit: 15, in_progress_count: 9, in_progress_count_limit: 10)
          pool = rating_pool(p => actuals(rpm_used: 1))

          norm = IntensityNorm.new.call(provider: p, operation: operation, pool: pool)

          assert_in_delta 0.933, norm, 0.001
        end
      end
    end
  end
end
