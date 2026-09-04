module PaymentRouting
  # Общие математические хелперы, переиспользуемые норм-калькуляторами,
  # чтобы клиппинг диапазонов не дублировался в каждом из них.
  module MathUtils
    module_function

    def clip(value, min, max)
      return min if value < min
      return max if value > max

      value
    end
  end
end
