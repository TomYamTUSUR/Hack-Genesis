# frozen_string_literal: true

# Pure calculations over one explicitly bounded cohort of operations.
module ProviderMinuteMetrics
  TERMINAL_STATUSES = %w[approved rejected expired].freeze
  AMOUNT_BANDS = [
    ['0_to_999', 0, 1000], ['1000_to_9999', 1000, 10_000],
    ['10000_to_49999', 10_000, 50_000], ['50000_to_99999', 50_000, 100_000],
    ['100000_and_above', 100_000, nil]
  ].freeze
  module_function

  def percentage(numerator, denominator)
    return nil if numerator.nil? || denominator.nil? || denominator <= 0

    (100.0 * numerator / denominator).round(4)
  end

  def change(current, previous)
    percentage(current - previous, previous)
  end

  def latency(values)
    sorted = values.compact.sort
    count = sorted.length
    return { 'count' => 0, 'avg_sec' => nil, 'median_sec' => nil, 'p95_sec' => nil } if count.zero?

    middle = count / 2
    {
      'count' => count,
      'avg_sec' => (sorted.sum.to_f / count).round(4),
      'median_sec' => count.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0,
      'p95_sec' => sorted[(count * 0.95).ceil - 1]
    }
  end

  def summary(rows)
    count = rows.length
    amount = rows.sum { |row| row.fetch('amount') }
    statuses = (TERMINAL_STATUSES + rows.map { |row| row['status'] || 'unknown' }).uniq.sort.to_h do |status|
      selected = rows.select { |row| (row['status'] || 'unknown') == status }
      status_amount = selected.sum { |row| row.fetch('amount') }
      [status, {
        'count' => selected.length, 'amount' => status_amount,
        'count_pct' => percentage(selected.length, count), 'amount_pct' => percentage(status_amount, amount)
      }]
    end
    approved = statuses.fetch('approved')
    terminal_count = TERMINAL_STATUSES.sum { |status| statuses.fetch(status).fetch('count') }
    {
      'count' => count, 'amount' => amount,
      'average_amount' => count.zero? ? nil : (amount.to_f / count).round(4),
      'min_amount' => rows.map { |row| row['amount'] }.min,
      'max_amount' => rows.map { |row| row['amount'] }.max,
      'statuses' => statuses,
      'approval_pct' => approved['count_pct'],
      'rejection_pct' => statuses.fetch('rejected')['count_pct'],
      'expiration_pct' => statuses.fetch('expired')['count_pct'],
      'approved_amount_pct' => approved['amount_pct'],
      'terminal_count' => terminal_count,
      'terminal_approval_pct' => percentage(approved['count'], terminal_count),
      'latency' => latency(rows.map { |row| row['latency_sec'] }),
      'approved_latency' => latency(rows.select { |row| row['status'] == 'approved' }.map { |row| row['latency_sec'] })
    }
  end

  def shares(metrics, total)
    metrics.merge(
      'count_share_pct' => percentage(metrics['count'], total['count']),
      'amount_share_pct' => percentage(metrics['amount'], total['amount']),
      'approved_amount_share_pct' => percentage(metrics.dig('statuses', 'approved', 'amount'), total.dig('statuses', 'approved', 'amount'))
    )
  end

  def breakdown(rows, total)
    banks = rows.group_by { |row| row['bank'] }.map do |bank, selected|
      shares(summary(selected), total).merge('bank' => bank)
    end.sort_by { |row| row['bank'].to_s }
    bands = AMOUNT_BANDS.map do |label, lower, upper|
      selected = rows.select { |row| row['amount'] >= lower && (upper.nil? || row['amount'] < upper) }
      shares(summary(selected), total).merge('band' => label, 'min_inclusive' => lower, 'max_exclusive' => upper)
    end
    { 'banks' => banks, 'amount_bands' => bands }
  end

  def target_gap(actual, target)
    actual.nil? || target.nil? ? nil : (actual - target).round(4)
  end

  def targets(provider, minute)
    {
      'target_count_share_pct' => provider['traffic_percentage'],
      'count_share_gap_pp' => target_gap(minute['count_share_pct'], provider['traffic_percentage']),
      'target_amount_share_pct' => provider['volume_share_pct'],
      'amount_share_gap_pp' => target_gap(minute['amount_share_pct'], provider['volume_share_pct']),
      'requests_limit' => provider['requests_per_minute_limit'],
      'requests_limit_utilization_pct' => percentage(minute['count'], provider['requests_per_minute_limit']),
      'requests_limit_remaining' => remaining(provider['requests_per_minute_limit'], minute['count']),
      # These are calculations from the supplied provider snapshot, not from
      # this minute's cohort. No timestamp exists to prove snapshot freshness.
      'snapshot_daily_approved_amount' => provider['daily_approved_amount'],
      'snapshot_daily_limit_utilization_pct' => percentage(provider['daily_approved_amount'], provider['daily_amount_limit']),
      'snapshot_daily_limit_remaining' => remaining(provider['daily_amount_limit'], provider['daily_approved_amount']),
      'snapshot_daily_minimum_fulfilled_pct' => percentage(provider['daily_approved_amount'], provider['daily_turnover_min']),
      'snapshot_daily_maximum_utilization_pct' => percentage(provider['daily_approved_amount'], provider['daily_turnover_max'])
    }
  end

  def remaining(limit, used)
    limit.nil? || used.nil? || limit <= 0 ? nil : limit - used
  end
end
