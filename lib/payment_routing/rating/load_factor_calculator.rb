module PaymentRouting
  module Rating
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

      def ratio(used, limit)
        return nil if limit.nil? || limit.zero?

        used.to_f / limit
      end
    end
  end
end
