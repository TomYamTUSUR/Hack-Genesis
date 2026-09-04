require_relative "../../../test_helper"

module PaymentRouting
  module Rating
    module Norms
      class ConversionNormTest < Minitest::Test
        include TestFactories

        def test_highest_conversion_in_the_pool_gets_the_maximum_norm
          vipay = provider(payment_system: "vipay", conversion_24h: 0.87)
          payflow = provider(payment_system: "payflow", conversion_24h: 0.91)
          quickpay = provider(payment_system: "quickpay", conversion_24h: 0.79)
          pool = rating_pool(vipay => actuals, payflow => actuals, quickpay => actuals)
          norm = ConversionNorm.new

          assert_in_delta 1.0, norm.call(provider: payflow, operation: operation, pool: pool), 0.0001
          assert_in_delta 0.0, norm.call(provider: quickpay, operation: operation, pool: pool), 0.0001
          assert_in_delta 0.6667, norm.call(provider: vipay, operation: operation, pool: pool), 0.001
        end
      end
    end
  end
end
