module PaymentRouting
  module Strategies
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
