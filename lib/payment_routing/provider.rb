module PaymentRouting
  # Провайдер как его видят блок стратегий/рейтинга и блок hard-constraints
  # (HardFilter, см. lib/payment_routing/hard_filter): параметры из таблицы
  # providers (db/operations.db).
  class Provider
    attr_reader :payment_system, :priority, :conversion_24h,
                :traffic_percentage, :volume_share_pct,
                # preferred_range (AmountRange) может быть nil - провайдер без
                # явного предпочтения по сумме чека, см. ProviderRegistry.
                :preferred_range, :requests_per_minute_limit, :daily_turnover_min,
                :in_progress_count, :in_progress_count_limit,
                :in_progress_amount, :in_progress_amount_limit,
                # Поля ниже нужны только HardFilter - блок стратегий/рейтинга их не
                # читает. Большинство лимитов (Integer/Float) может быть nil -
                # это "без ограничения", а не "ограничение в 0", см. правила в
                # lib/payment_routing/hard_filter/rules.
                :status, :limit_amount_min, :limit_amount_max,
                :daily_amount_limit, :daily_approved_amount,
                :available_requisites,
                # banks - Array[String] (см. ProviderRegistry - парсится из JSON-колонки);
                # [] значит "без ограничения по банкам" независимо от exclude_banks.
                :banks, :exclude_banks,
                :provider_margin_pct, :merchant_margin_pct, :allow_negative_agreement,
                :daily_turnover_max,
                # avg_latency_sec - только для Router (latency_sec в итоговом решении).
                # Опциональный (default nil), чтобы не ломать существующие вызовы
                # Provider.new (ProviderRegistry передаёт реальное значение).
                :avg_latency_sec

    def initialize(payment_system:, priority:, conversion_24h:, traffic_percentage:,
                   volume_share_pct:, preferred_range:, requests_per_minute_limit:,
                   daily_turnover_min:, in_progress_count:, in_progress_count_limit:,
                   in_progress_amount:, in_progress_amount_limit:,
                   status:, limit_amount_min:, limit_amount_max:,
                   daily_amount_limit:, daily_approved_amount:,
                   available_requisites:, banks:, exclude_banks:,
                   provider_margin_pct:, merchant_margin_pct:, allow_negative_agreement:,
                   daily_turnover_max:, avg_latency_sec: nil)
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
    end

    # Иммутабельное обновление: возвращает новый Provider с указанными полями
    # изменёнными, остальные - как есть. Используется Router::MetricsUpdater,
    # чтобы обновлять рантайм-состояние между операциями одного прогона, не
    # заводя мутирующих методов на самом Provider.
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
        avg_latency_sec: avg_latency_sec
      }
    end
  end
end
