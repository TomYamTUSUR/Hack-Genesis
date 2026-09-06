module PaymentRouting
  # Фактические показатели провайдера "на сейчас", нужные soft-goal
  class ProviderActuals
    attr_reader :count_share_actual, :volume_share_actual, :count_actual, :volume_actual, :turnover_actual, :rpm_used, :request_times

    def initialize(count_share_actual:, volume_share_actual:, count_actual:, volume_actual:, turnover_actual:, rpm_used:, request_times: nil)
      @count_share_actual = count_share_actual
      @volume_share_actual = volume_share_actual
      @count_actual = count_actual
      @volume_actual = volume_actual
      @turnover_actual = turnover_actual
      @rpm_used = rpm_used
      @request_times = request_times
    end

    def with(**overrides)
      self.class.new(**to_h.merge(overrides))
    end

    def to_h
      {
        count_share_actual: count_share_actual, volume_share_actual: volume_share_actual,
        count_actual: count_actual, volume_actual: volume_actual,
        turnover_actual: turnover_actual, rpm_used: rpm_used, request_times: request_times
      }
    end
  end
end
