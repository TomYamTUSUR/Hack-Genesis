#!/usr/bin/env ruby
# Демонстрация блока стратегий + блока рейтинга на данных из db/operations.db
# (запустите bin/import_data.rb заранее, если БД пустая или отсутствует).
# Не участвует в hard-constraints - показывает только, как смена активной
# стратегии меняет ранжирование провайдеров.

require_relative "../lib/payment_routing"
require_relative "../db/database"

module PaymentRouting
  # Прогоняет несколько наборов активных стратегий через реальные конфиги и
  # печатает ранжирование с разбивкой по нормам - для наглядной проверки на чекпоинте.
  class RatingDemo
    SCENARIOS = [
      { label: "solo: приоритет (каскад)", active_keys: [:priority] },
      { label: "solo: конверсия", active_keys: [:conversion] },
      { label: "solo: интенсивность", active_keys: [:intensity] },
      { label: "combo: объём + приоритет + конверсия", active_keys: %i[volume_share priority conversion] }
    ].freeze

    DEMO_OPERATION = Operation.new(operation_id: "demo_op", amount: 30_000).freeze

    def initialize
      config = RoutingConfig.new
      db = Db.connect

      @providers = ProviderRegistry.new(db: db, rated_providers: config.rated_providers).load
      raise "db/operations.db пуста - сначала запустите bin/import_data.rb" if @providers.empty?

      @actuals_by_provider = HistoricalActualsProvider.new(db: db).load

      @strategy_calculator = Strategies::StrategyWeightCalculator.new(
        registry: Strategies::StrategyRegistry.new(strategies_file: config.strategies_file)
      )
    end

    def run
      SCENARIOS.each { |scenario| print_scenario(scenario) }
    end

    private

    def print_scenario(scenario)
      weights_and_gamma = @strategy_calculator.call(active_keys: scenario[:active_keys])
      calculator = Rating::ProviderScoreCalculator.new(weights: weights_and_gamma[:weights], gamma: weights_and_gamma[:gamma])
      ranked = calculator.rank(providers: @providers, actuals_by_provider: @actuals_by_provider, operation: DEMO_OPERATION)

      puts "=== #{scenario[:label]} (gamma=#{weights_and_gamma[:gamma]}) ==="
      ranked.each_with_index do |result, index|
        breakdown = result.breakdown.map { |key, value| "#{key}=#{value.round(3)}" }.join(", ")
        puts "  #{index + 1}. #{result.provider.payment_system}: score=#{result.score.round(2)}  [#{breakdown}]"
      end
      puts
    end
  end
end

PaymentRouting::RatingDemo.new.run if $PROGRAM_NAME == __FILE__
