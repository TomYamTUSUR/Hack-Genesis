module PaymentRouting
  module Rating
    module Norms
      class RangeFitNorm < BaseNorm
        KEY = :range_fit

        def call(provider:, operation:, pool:)
          range = provider.preferred_range
          return Constants::NORM_MAX if range.nil? || range.halfwidth.zero?

          fit = 1 - (operation.amount - range.mid).abs / range.halfwidth
          MathUtils.clip(fit, Constants::NORM_MIN, Constants::NORM_MAX)
        end
      end
    end
  end
end
