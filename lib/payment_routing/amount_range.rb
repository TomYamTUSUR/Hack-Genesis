module PaymentRouting
  class AmountRange
    attr_reader :min, :max

    def initialize(min:, max:)
      @min = min.to_f
      @max = max.to_f
    end

    def mid
      (min + max) / 2.0
    end

    def halfwidth
      (max - min) / 2.0
    end
  end
end
