module PaymentRouting
  module Strategies
    # Данные из config/strategies.yml: ключ стратегии и её вес в combo-режиме.
    StrategyDefinition = Struct.new(:key, :combo_coefficient, keyword_init: true)
  end
end
