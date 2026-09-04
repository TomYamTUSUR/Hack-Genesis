module PaymentRouting
  module Strategies
    # Блок стратегий: по списку активных ключей считает вес w_i каждой из
    # зарегистрированных стратегий и показатель степени gamma для LoadFactor.
    # Ничего не знает о провайдерах/операциях - чистая функция конфига.
    class StrategyWeightCalculator
      INTENSITY_KEY = :intensity

      def initialize(registry:)
        @definitions_by_key = registry.all.each_with_object({}) { |definition, hash| hash[definition.key] = definition }
      end

      def call(active_keys:)
        raise ArgumentError, "at least one active strategy is required" if active_keys.empty?

        weights = active_keys.size == 1 ? solo_weights(active_keys.first) : combo_weights(active_keys)
        { weights: weights, gamma: gamma_for(active_keys) }
      end

      private

      def solo_weights(active_key)
        other_keys = @definitions_by_key.keys - [active_key]
        other_weight = [
          Constants::SOLO_OTHERS_TOTAL_WEIGHT / other_keys.size,
          Constants::SOLO_OTHER_MIN_WEIGHT
        ].max

        @definitions_by_key.keys.to_h do |key|
          [key, key == active_key ? Constants::SOLO_TARGET_WEIGHT : other_weight]
        end
      end

      def combo_weights(active_keys)
        coefficient_sum = active_keys.sum { |key| @definitions_by_key.fetch(key).combo_coefficient }

        @definitions_by_key.keys.to_h do |key|
          weight = active_keys.include?(key) ? @definitions_by_key.fetch(key).combo_coefficient / coefficient_sum : 0.0
          [key, weight]
        end
      end

      def gamma_for(active_keys)
        active_keys.include?(INTENSITY_KEY) ? Constants::INTENSITY_GAMMA : Constants::DEFAULT_GAMMA
      end
    end
  end
end
