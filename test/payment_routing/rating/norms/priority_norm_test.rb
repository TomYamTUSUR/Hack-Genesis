require_relative "../../../test_helper"

module PaymentRouting
  module Rating
    module Norms
      class PriorityNormTest < Minitest::Test
        include TestFactories

        def test_lowest_priority_number_gets_the_highest_norm
          vipay = provider(payment_system: "vipay", priority: 1)
          payflow = provider(payment_system: "payflow", priority: 2)
          quickpay = provider(payment_system: "quickpay", priority: 3)
          pool = rating_pool(vipay => actuals, payflow => actuals, quickpay => actuals)
          norm = PriorityNorm.new

          assert_in_delta 1.0, norm.call(provider: vipay, operation: operation, pool: pool), 0.0001
          assert_in_delta 0.5, norm.call(provider: payflow, operation: operation, pool: pool), 0.0001
          assert_in_delta 0.0, norm.call(provider: quickpay, operation: operation, pool: pool), 0.0001
        end

        def test_single_candidate_pool_gets_the_maximum_norm
          vipay = provider(payment_system: "vipay", priority: 1)
          pool = rating_pool(vipay => actuals)

          assert_equal 1.0, PriorityNorm.new.call(provider: vipay, operation: operation, pool: pool)
        end
      end
    end
  end
end
