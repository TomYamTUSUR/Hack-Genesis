module PaymentRouting
  module Rating
    module Norms
      class PriorityNorm < BaseNorm
        KEY = :priority

        def call(provider:, operation:, pool:)
          min_max_norm(
            value: pool.max_priority - provider.priority,
            min: 0,
            max: pool.max_priority - pool.min_priority
          )
        end
      end
    end
  end
end
