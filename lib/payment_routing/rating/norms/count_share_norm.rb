module PaymentRouting
  module Rating
    module Norms
      class CountShareNorm < BaseNorm
        KEY = :count_share

        def call(provider:, operation:, pool:)
          deviation_norm(target: provider.traffic_percentage, actual: pool.actuals_for(provider).count_share_actual)
        end
      end
    end
  end
end
