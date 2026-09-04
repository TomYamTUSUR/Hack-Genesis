require_relative "../../test_helper"

module PaymentRouting
  module Rating
    class LoadFactorCalculatorTest < Minitest::Test
      include TestFactories

      def setup
        @calculator = LoadFactorCalculator.new
      end

      def test_utilization_is_zero_when_no_limits_are_set
        p = provider(requests_per_minute_limit: nil, in_progress_count_limit: nil, in_progress_amount_limit: nil)

        assert_equal 0.0, @calculator.utilization(provider: p, actuals: actuals(rpm_used: 0))
      end

      def test_utilization_takes_the_highest_ratio_among_available_limits
        p = provider(
          requests_per_minute_limit: 20, in_progress_count: 4, in_progress_count_limit: 10,
          in_progress_amount: 380_000, in_progress_amount_limit: 1_000_000
        )

        assert_in_delta 0.75, @calculator.utilization(provider: p, actuals: actuals(rpm_used: 15)), 0.0001
      end

      def test_utilization_is_clipped_at_one_when_over_committed
        p = provider(in_progress_count: 12, in_progress_count_limit: 10)

        assert_equal 1.0, @calculator.utilization(provider: p, actuals: actuals(rpm_used: 0))
      end

      def test_load_factor_raises_utilization_complement_to_gamma
        assert_in_delta 0.25, @calculator.load_factor(utilization: 0.5, gamma: 2), 0.0001
      end
    end
  end
end
