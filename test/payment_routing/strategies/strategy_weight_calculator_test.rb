require_relative "../../test_helper"

module PaymentRouting
  module Strategies
    class StrategyWeightCalculatorTest < Minitest::Test
      def setup
        registry = StrategyRegistry.new(strategies_file: RoutingConfig.new.strategies_file)
        @calculator = StrategyWeightCalculator.new(registry: registry)
      end

      def test_solo_gives_target_weight_to_active_strategy_and_floor_to_the_rest
        result = @calculator.call(active_keys: [:priority])

        assert_in_delta Constants::SOLO_TARGET_WEIGHT, result[:weights][:priority], 0.0001
        (result[:weights].keys - [:priority]).each do |key|
          assert_in_delta Constants::SOLO_OTHER_MIN_WEIGHT, result[:weights][key], 0.0001
        end
        assert_in_delta 1.0, result[:weights].values.sum, 0.0001
      end

      def test_combo_splits_weight_proportionally_to_combo_coefficient
        result = @calculator.call(active_keys: %i[volume_share priority conversion])

        assert_in_delta 0.270, result[:weights][:volume_share], 0.001
        assert_in_delta 0.432, result[:weights][:priority], 0.001
        assert_in_delta 0.297, result[:weights][:conversion], 0.001
        assert_equal 0.0, result[:weights][:count_share]
        assert_equal 0.0, result[:weights][:range_fit]
        assert_equal 0.0, result[:weights][:intensity]
        assert_equal 0.0, result[:weights][:turnover]
      end

      def test_gamma_switches_to_intensity_value_only_when_intensity_is_active
        assert_equal Constants::DEFAULT_GAMMA, @calculator.call(active_keys: [:priority])[:gamma]
        assert_equal Constants::INTENSITY_GAMMA, @calculator.call(active_keys: [:intensity])[:gamma]
        assert_equal Constants::INTENSITY_GAMMA, @calculator.call(active_keys: %i[priority intensity])[:gamma]
      end

      def test_raises_when_no_strategy_is_active
        assert_raises(ArgumentError) { @calculator.call(active_keys: []) }
      end
    end
  end
end
