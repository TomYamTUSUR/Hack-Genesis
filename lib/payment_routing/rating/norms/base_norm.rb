module PaymentRouting
  module Rating
    module Norms
      class BaseNorm
        KEY = nil

        def call(provider:, operation:, pool:)
          raise NotImplementedError, "#{self.class} must implement #call"
        end

        def deviation_norm(target:, actual:)
          return Constants::SINGLE_CANDIDATE_NORM if target.nil? || target.zero?

          relative_deviation = MathUtils.clip(
            (target - actual).to_f / target,
            Constants::RELATIVE_DEVIATION_MIN,
            Constants::RELATIVE_DEVIATION_MAX
          )
          (relative_deviation + 1) / 2.0
        end

        def min_max_norm(value:, min:, max:)
          return Constants::SINGLE_CANDIDATE_NORM if min == max

          (value - min).to_f / (max - min)
        end
      end
    end
  end
end
