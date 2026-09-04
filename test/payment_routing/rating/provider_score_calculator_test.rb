require_relative "../../test_helper"

module PaymentRouting
  module Rating
    # Интеграционный тест на реальных данных, загруженных в БД - показывает, что
    # смена активной стратегии (solo) меняет победителя ранжирования, как и
    # задумано формулой (её ключевой критерий получает вес 0.70).
    class ProviderScoreCalculatorTest < Minitest::Test
      include TestFactories

      def setup
        config = RoutingConfig.new
        db = seeded_db

        @providers = ProviderRegistry.new(db: db, rated_providers: config.rated_providers).load

        # Нейтральные actuals: каждый провайдер точно на своей целевой доле/обороте,
        # чтобы deviation-нормы не искажали сравнение конкретно проверяемой стратегии.
        @actuals_by_provider = @providers.to_h do |p|
          [p.payment_system, ProviderActuals.new(
            count_share_actual: p.traffic_percentage,
            volume_share_actual: p.volume_share_pct,
            turnover_actual: p.daily_turnover_min || 0,
            rpm_used: 0
          )]
        end

        @operation = Operation.new(operation_id: "op_test", amount: 10_000)
        @registry = Strategies::StrategyRegistry.new(strategies_file: config.strategies_file)
      end

      def test_solo_intensity_strategy_ranks_the_least_loaded_provider_first
        assert_equal "quickpay", top_provider(active_keys: [:intensity]).payment_system
      end

      def test_solo_conversion_strategy_ranks_the_highest_conversion_provider_first
        assert_equal "payflow", top_provider(active_keys: [:conversion]).payment_system
      end

      private

      def top_provider(active_keys:)
        weights_and_gamma = Strategies::StrategyWeightCalculator.new(registry: @registry).call(active_keys: active_keys)
        calculator = ProviderScoreCalculator.new(weights: weights_and_gamma[:weights], gamma: weights_and_gamma[:gamma])

        calculator.rank(providers: @providers, actuals_by_provider: @actuals_by_provider, operation: @operation).first.provider
      end
    end
  end
end
