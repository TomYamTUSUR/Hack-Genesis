#!/usr/bin/env ruby
# Демонстрация HardFilter (lib/payment_routing/hard_filter) - по одному
# сценарию на каждую из 9 проверок из ТЗ, плюс сценарий "всё в порядке" и
# сценарий с несколькими одновременными нарушениями (показывает, что Engine
# копит все причины, а не только первую - см. HardFilter::Result).
#
# Специально не читает db/operations.db - его пока может не быть (see README:
# `bundle exec ruby db/create_tables.rb` создаёт пустую схему, провайдеров
# заполняет отдельный импорт). Один и тот же Engine потом можно натравить на
# ProviderRegistry.load + HistoricalActualsProvider.load вместо этих
# синтетических Provider/Operation - интерфейс (provider:, operation:, actuals:)
# не меняется.

require_relative "../lib/payment_routing"

module PaymentRouting
  class HardFilterDemo
    # "Здоровый" провайдер, который проходит все 9 проверок - каждый сценарий
    # ниже переопределяет только то, что нужно для нарушения конкретного правила,
    # чтобы было видно эффект именно этого правила.
    def self.healthy_provider(overrides = {})
      Provider.new(
        **{
          payment_system: "demo_provider", priority: 1, conversion_24h: 0.9,
          traffic_percentage: 100, volume_share_pct: 100, preferred_range: nil,
          requests_per_minute_limit: 60, daily_turnover_min: nil,
          in_progress_count: 2, in_progress_count_limit: 10,
          in_progress_amount: 50_000, in_progress_amount_limit: 1_000_000,
          status: "active", limit_amount_min: 1_000, limit_amount_max: 100_000,
          daily_amount_limit: 5_000_000, daily_approved_amount: 1_000_000,
          available_requisites: 5, banks: %w[sberbank tinkoff], exclude_banks: false,
          provider_margin_pct: 1.0, merchant_margin_pct: 1.5, allow_negative_agreement: false,
          daily_turnover_max: 4_000_000
        }.merge(overrides)
      )
    end

    def self.healthy_operation(overrides = {})
      Operation.new(**{ operation_id: "demo_op", amount: 30_000, bank: "sberbank" }.merge(overrides))
    end

    def self.healthy_actuals(overrides = {})
      ProviderActuals.new(**{ count_share_actual: 0, volume_share_actual: 0, turnover_actual: 500_000, rpm_used: 10 }.merge(overrides))
    end

    SCENARIOS = [
      { label: "1. всё в порядке - провайдер проходит", provider: {}, operation: {}, actuals: {} },
      { label: "2. Статус: провайдер отключён", provider: { status: "paused" }, operation: {}, actuals: {} },
      { label: "3. Диапазон суммы чека: ниже минимума", provider: {}, operation: { amount: 500 }, actuals: {} },
      { label: "4. Диапазон суммы чека: выше максимума", provider: {}, operation: { amount: 150_000 }, actuals: {} },
      { label: "5. Дневной максимум: операция уводит выше daily_amount_limit",
        provider: { daily_approved_amount: 4_990_000 }, operation: {}, actuals: {} },
      { label: "6. In-progress count: уже на лимите", provider: { in_progress_count: 10 }, operation: {}, actuals: {} },
      { label: "7. In-progress amount: операция уводит выше лимита",
        provider: { in_progress_amount: 980_000 }, operation: {}, actuals: {} },
      { label: "8. Банковский фильтр (whitelist): банк не входит в список",
        provider: {}, operation: { bank: "vtb" }, actuals: {} },
      { label: "9. Банковский фильтр (blacklist): банк в чёрном списке",
        provider: { banks: %w[vtb], exclude_banks: true }, operation: { bank: "vtb" }, actuals: {} },
      { label: "10. Маржа: провайдер просит больше мерчантской, без разрешения",
        provider: { provider_margin_pct: 2.0 }, operation: {}, actuals: {} },
      { label: "10a. Маржа: то же самое, но allow_negative_agreement=true - проходит",
        provider: { provider_margin_pct: 2.0, allow_negative_agreement: true }, operation: {}, actuals: {} },
      { label: "11. Реквизиты: нечем принять выплату", provider: { available_requisites: 0 }, operation: {}, actuals: {} },
      { label: "12. Интенсивность: rate limit превышен",
        provider: {}, operation: {}, actuals: { rpm_used: 61 } },
      { label: "13. Фин. обязательство (максимум): операция уводит выше daily_turnover_max",
        provider: {}, operation: {}, actuals: { turnover_actual: 3_980_000 } },
      { label: "14. Несколько нарушений сразу - Engine копит ВСЕ причины",
        provider: { status: "paused", available_requisites: 0 }, operation: { bank: "vtb" }, actuals: {} }
    ].freeze

    def run
      engine = HardFilter::Engine.new

      SCENARIOS.each do |scenario|
        provider = self.class.healthy_provider(scenario[:provider])
        operation = self.class.healthy_operation(scenario[:operation])
        actuals = self.class.healthy_actuals(scenario[:actuals])

        result = engine.call(provider: provider, operation: operation, actuals: actuals)

        status = result.eligible? ? "ELIGIBLE" : "EXCLUDED"
        reasons = result.reasons.empty? ? "-" : result.reasons.join(", ")
        puts "#{scenario[:label]}\n  => #{status} (reasons: #{reasons})\n\n"
      end
    end
  end
end

PaymentRouting::HardFilterDemo.new.run if $PROGRAM_NAME == __FILE__
