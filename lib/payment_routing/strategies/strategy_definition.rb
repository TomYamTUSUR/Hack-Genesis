module PaymentRouting
  module Strategies
    StrategyDefinition = Struct.new(:key, :combo_coefficient, keyword_init: true)
  end
end
