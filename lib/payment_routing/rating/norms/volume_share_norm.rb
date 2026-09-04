module PaymentRouting
  module Rating
    module Norms
      # Стратегия 2: доля по объёму (рубли), а не по количеству операций.
      class VolumeShareNorm < BaseNorm
        KEY = :volume_share

        def call(provider:, operation:, pool:)
          deviation_norm(target: provider.volume_share_pct, actual: pool.actuals_for(provider).volume_share_actual)
        end
      end
    end
  end
end
