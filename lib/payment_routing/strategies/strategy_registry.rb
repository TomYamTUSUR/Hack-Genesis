module PaymentRouting
  module Strategies
    # Загружает полный список известных стратегий (и их combo-коэффициентов)
    # из config/strategies.yml. Не знает про провайдеров и про то, какие
    # стратегии активны сейчас - это дело StrategyWeightCalculator.
    class StrategyRegistry
      def initialize(strategies_file:)
        @strategies_file = strategies_file
      end

      def all
        @all ||= YAML.safe_load(File.read(@strategies_file))["strategies"].map do |raw|
          StrategyDefinition.new(key: raw["key"].to_sym, combo_coefficient: raw["combo_coefficient"])
        end
      end
    end
  end
end
