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

    def percentage_of(part, total)
      return 0.0 if total.zero?

      100.0 * part / total
    end
  end
end
