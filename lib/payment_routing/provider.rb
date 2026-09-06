module PaymentRouting
  class Provider
    attr_reader :payment_system, :priority, :conversion_24h,
                :traffic_percentage, :volume_share_pct,
                :preferred_range, :requests_per_minute_limit, :daily_turnover_min,
                :in_progress_count, :in_progress_count_limit,
                :in_progress_amount, :in_progress_amount_limit,
                :status, :limit_amount_min, :limit_amount_max,
                :daily_amount_limit, :daily_approved_amount,
                :available_requisites,
                :banks, :exclude_banks,
                :provider_margin_pct, :merchant_margin_pct, :allow_negative_agreement,
                :daily_turnover_max,
                :avg_latency_sec, :daily_approved_date, :daily_utc_offset

    def initialize(payment_system:, priority:, conversion_24h:, traffic_percentage:,
                   volume_share_pct:, preferred_range:, requests_per_minute_limit:,
                   daily_turnover_min:, in_progress_count:, in_progress_count_limit:,
                   in_progress_amount:, in_progress_amount_limit:,
                   status:, limit_amount_min:, limit_amount_max:,
                   daily_amount_limit:, daily_approved_amount:,
                   available_requisites:, banks:, exclude_banks:,
                   provider_margin_pct:, merchant_margin_pct:, allow_negative_agreement:,
                   daily_turnover_max:, avg_latency_sec: nil, daily_approved_date: nil, daily_utc_offset: 0)
      @payment_system = payment_system
      @priority = priority
      @conversion_24h = conversion_24h
      @traffic_percentage = traffic_percentage
      @volume_share_pct = volume_share_pct
      @preferred_range = preferred_range
      @requests_per_minute_limit = requests_per_minute_limit
      @daily_turnover_min = daily_turnover_min
      @in_progress_count = in_progress_count
      @in_progress_count_limit = in_progress_count_limit
      @in_progress_amount = in_progress_amount
      @in_progress_amount_limit = in_progress_amount_limit
      @status = status
      @limit_amount_min = limit_amount_min
      @limit_amount_max = limit_amount_max
      @daily_amount_limit = daily_amount_limit
      @daily_approved_amount = daily_approved_amount
      @available_requisites = available_requisites
      @banks = banks
      @exclude_banks = exclude_banks
      @provider_margin_pct = provider_margin_pct
      @merchant_margin_pct = merchant_margin_pct
      @allow_negative_agreement = allow_negative_agreement
      @daily_turnover_max = daily_turnover_max
      @avg_latency_sec = avg_latency_sec
      @daily_approved_date = daily_approved_date
      @daily_utc_offset = daily_utc_offset || 0
    end

    def with(**overrides)
      self.class.new(**to_h.merge(overrides))
    end

    def to_h
      {
        payment_system: payment_system, priority: priority, conversion_24h: conversion_24h,
        traffic_percentage: traffic_percentage, volume_share_pct: volume_share_pct,
        preferred_range: preferred_range, requests_per_minute_limit: requests_per_minute_limit,
        daily_turnover_min: daily_turnover_min, in_progress_count: in_progress_count,
        in_progress_count_limit: in_progress_count_limit, in_progress_amount: in_progress_amount,
        in_progress_amount_limit: in_progress_amount_limit, status: status,
        limit_amount_min: limit_amount_min, limit_amount_max: limit_amount_max,
        daily_amount_limit: daily_amount_limit, daily_approved_amount: daily_approved_amount,
        available_requisites: available_requisites, banks: banks, exclude_banks: exclude_banks,
        provider_margin_pct: provider_margin_pct, merchant_margin_pct: merchant_margin_pct,
        allow_negative_agreement: allow_negative_agreement, daily_turnover_max: daily_turnover_max,
        avg_latency_sec: avg_latency_sec, daily_approved_date: daily_approved_date, daily_utc_offset: daily_utc_offset
      }
    end
  end
end
