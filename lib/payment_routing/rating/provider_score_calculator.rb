module PaymentRouting
  module Rating
    # Результат ранжирования одного провайдера: итоговый Score и разбивка по
    # нормам (пригодится для объяснимости решения - attempts/details).
    ScoreResult = Struct.new(:provider, :score, :breakdown, keyword_init: true)

    # Блок распределения рейтинга: Score(p) = 100 * Σ(w_i * norm_i(p)) * LoadFactor(p)^gamma.
    # Ничего не знает про то, откуда взялись weights/gamma (это StrategyWeightCalculator).
    class ProviderScoreCalculator
      def initialize(weights:, gamma:, load_factor_calculator: LoadFactorCalculator.new, norms: nil)
        @weights = weights
        @gamma = gamma
        @load_factor_calculator = load_factor_calculator
        @norms = norms || default_norms
      end

      def rank(providers:, actuals_by_provider:, operation:)
        pool = RatingPool.new(providers: providers, actuals_by_provider: actuals_by_provider)

        providers
          .map { |provider| score_for(provider, operation, pool) }
          .sort_by { |result| -result.score }
      end

      private

      def score_for(provider, operation, pool)
        breakdown = {}
        weighted_sum = @norms.sum do |norm|
          norm_value = norm.call(provider: provider, operation: operation, pool: pool)
          breakdown[norm.class::KEY] = norm_value
          @weights.fetch(norm.class::KEY, 0.0) * norm_value
        end

        utilization = @load_factor_calculator.utilization(provider: provider, actuals: pool.actuals_for(provider))
        load_factor = @load_factor_calculator.load_factor(utilization: utilization, gamma: @gamma)

        ScoreResult.new(provider: provider, score: Constants::SCORE_SCALE * weighted_sum * load_factor, breakdown: breakdown)
      end

      def default_norms
        [
          Norms::CountShareNorm.new,
          Norms::VolumeShareNorm.new,
          Norms::PriorityNorm.new,
          Norms::RangeFitNorm.new,
          Norms::ConversionNorm.new,
          Norms::IntensityNorm.new(load_factor_calculator: @load_factor_calculator),
          Norms::TurnoverNorm.new
        ]
      end
    end
  end
end
