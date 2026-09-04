module PaymentRouting
  module Rating
    # u(p) и LoadFactor(p)^gamma - универсальный множитель рейтинга, учитывающий
    # любое из трёх измерений загрузки (rpm, in-progress count/amount) сразу -
    # чтобы не обращаться к провайдеру, упёршемуся в любой из своих лимитов.
    #
    # rpm_utilization отдельно нужен Norms::IntensityNorm: стратегия "по
    # интенсивности" (rate limit) - про требования/минуту конкретно, а не про
    # общую загрузку, поэтому её ключевая норма не должна зависеть от того,
    # сколько у провайдера сейчас in-progress заявок.
    class LoadFactorCalculator
      def utilization(provider:, actuals:)
        ratios = [
          ratio(actuals.rpm_used, provider.requests_per_minute_limit),
          ratio(provider.in_progress_count, provider.in_progress_count_limit),
          ratio(provider.in_progress_amount, provider.in_progress_amount_limit)
        ].compact

        return Constants::UNDEFINED_UTILIZATION if ratios.empty?

        MathUtils.clip(ratios.max, Constants::NORM_MIN, Constants::NORM_MAX)
      end

      def rpm_utilization(provider:, actuals:)
        rpm_ratio = ratio(actuals.rpm_used, provider.requests_per_minute_limit)
        return Constants::UNDEFINED_UTILIZATION if rpm_ratio.nil?

        MathUtils.clip(rpm_ratio, Constants::NORM_MIN, Constants::NORM_MAX)
      end

      def load_factor(utilization:, gamma:)
        (1 - utilization)**gamma
      end

      private

      # Лимит может отсутствовать (nil) или быть 0 - в обоих случаях эта
      # составляющая нагрузки не участвует в u(p), а не считается "перегрузом".
      def ratio(used, limit)
        return nil if limit.nil? || limit.zero?

        used.to_f / limit
      end
    end
  end
end
