#!/usr/bin/env ruby
# frozen_string_literal: true

# Export routing_report_test.json from the project root to six Excel sheets.
# Usage: bundle exec ruby bin/generate_excel_report.rb [input.json] [output.xlsx]
# Default output: routing_analytics.xlsx next to the input JSON.
# Install dependencies with bundle install. Run --help for default paths.

require 'json'
require 'optparse'
require 'fileutils'
require 'tempfile'
require_relative '../lib/excel_report_input'

begin
  parser = OptionParser.new do |options|
    options.banner = 'Usage: bundle exec ruby bin/generate_excel_report.rb [input.json] [output.xlsx]'
    options.separator 'Default input: routing_report_test.json (relative to project).'
    options.separator 'Default output: routing_analytics.xlsx next to the input JSON.'
    options.on('-h', '--help', 'Show this help') { puts options; exit 0 }
  end
  parser.parse!
  raise ArgumentError, parser.banner if ARGV.size > 2

  input_path = File.expand_path(ARGV[0] || '../routing_report_test.json', ARGV[0] ? Dir.pwd : __dir__)
  output_path = File.expand_path(ARGV[1] || File.join(File.dirname(input_path), 'routing_analytics.xlsx'))
  raise ArgumentError, 'Output must have the .xlsx extension' unless File.extname(output_path).casecmp?('.xlsx')
  if input_path.casecmp?(output_path) || (File.exist?(output_path) && File.identical?(input_path, output_path))
    raise ArgumentError, 'Input and output must be different files'
  end

  data = JSON.parse(File.read(input_path, encoding: 'bom|UTF-8'))
  RoutingAnalytics::ExcelReportInput.validate!(data)

  begin
    require 'caxlsx'
  rescue LoadError
    abort('Missing caxlsx dependency. Run bundle install, then bundle exec ruby bin/generate_excel_report.rb.')
  end

# ============================================================
# Helpers
# ============================================================

def value(hash, *keys)
  keys.reduce(hash) do |memo, key|
    memo.is_a?(Hash) ? memo[key] : nil
  end
end

def safe_number(value, fallback = 0)
  value.nil? ? fallback : value
end

def deviation(metrics)
  return metrics['deviation_pp'] unless metrics['deviation_pp'].nil?
  return nil if metrics['share_pct'].nil? || metrics['target_pct'].nil?

  (metrics['share_pct'] - metrics['target_pct']).round(2)
end

def approval_style(rate, styles)
  return styles[:muted] if rate.nil?
  return styles[:heat_bad] if rate < 60
  return styles[:heat_warn] if rate < 80

  styles[:heat_good]
end

# ============================================================
# Excel
# ============================================================

package  = Axlsx::Package.new
workbook = package.workbook
workbook.escape_formulas = true
s        = workbook.styles

border = {
  style: :thin,
  color: 'FFD9E1F2',
  edges: :all
}

# ============================================================
# Стили
# ============================================================

styles = {
  title: s.add_style(
    bg_color: 'FF1F4E78',
    fg_color: 'FFFFFFFF',
    b: true,
    sz: 18,
    alignment: {
      horizontal: :center,
      vertical: :center
    },
    border: border
  ),

  section: s.add_style(
    bg_color: 'FF5B9BD5',
    fg_color: 'FFFFFFFF',
    b: true,
    sz: 12,
    alignment: {
      horizontal: :left,
      vertical: :center
    },
    border: border
  ),

  header: s.add_style(
    bg_color: 'FFD9EAF7',
    fg_color: 'FF1F1F1F',
    b: true,
    alignment: {
      horizontal: :center,
      vertical: :center,
      wrap_text: true
    },
    border: border
  ),

  cell: s.add_style(
    border: border,
    alignment: {
      vertical: :center
    }
  ),

  cell_center: s.add_style(
    border: border,
    alignment: {
      horizontal: :center,
      vertical: :center
    }
  ),

  integer: s.add_style(
    border: border,
    format_code: '#,##0'
  ),

  decimal: s.add_style(
    border: border,
    format_code: '#,##0.00'
  ),

  percent_points: s.add_style(
    border: border,
    format_code: '0.00\%'
  ),

  seconds: s.add_style(
    border: border,
    format_code: '0.00\ \s'
  ),

  kpi_label: s.add_style(
    bg_color: 'FFEAF2F8',
    fg_color: 'FF44546A',
    b: true,
    alignment: {
      horizontal: :center,
      vertical: :center
    },
    border: border
  ),

  kpi_value: s.add_style(
    bg_color: 'FFFFFFFF',
    fg_color: 'FF1F4E78',
    b: true,
    sz: 16,
    alignment: {
      horizontal: :center,
      vertical: :center
    },
    border: border
  ),

  warning: s.add_style(
    format_code: '0.00\%',
    bg_color: 'FFFFE699',
    fg_color: 'FF7F6000',
    b: true,
    alignment: {
      horizontal: :center
    },
    border: border
  ),

  danger: s.add_style(
    format_code: '0.00\%',
    bg_color: 'FFF4CCCC',
    fg_color: 'FF9C0006',
    b: true,
    alignment: {
      horizontal: :center
    },
    border: border
  ),

  good: s.add_style(
    format_code: '0.00\%',
    bg_color: 'FFD9EAD3',
    fg_color: 'FF274E13',
    b: true,
    alignment: {
      horizontal: :center
    },
    border: border
  ),

  muted: s.add_style(
    bg_color: 'FFF2F2F2',
    fg_color: 'FF7F7F7F',
    alignment: {
      horizontal: :center
    },
    border: border
  ),

  heat_bad: s.add_style(
    bg_color: 'FFF4CCCC',
    fg_color: 'FF9C0006',
    border: border,
    format_code: '0.00\%'
  ),

  heat_warn: s.add_style(
    bg_color: 'FFFFE599',
    fg_color: 'FF7F6000',
    border: border,
    format_code: '0.00\%'
  ),

  heat_good: s.add_style(
    bg_color: 'FFD9EAD3',
    fg_color: 'FF274E13',
    border: border,
    format_code: '0.00\%'
  ),

  recommendation: s.add_style(
    border: border,
    alignment: {
      vertical: :top,
      wrap_text: true
    }
  )
}

# ============================================================
# 1. DASHBOARD
# ============================================================

workbook.add_worksheet(name: 'Dashboard') do |sheet|

  sheet.add_row(
    ['SMART ROUTING ANALYTICS', nil, nil, nil, nil, nil, nil, nil],
    style: styles[:title],
    height: 26
  )

  sheet.add_row(
    Array.new(8),
    style: styles[:title],
    height: 8
  )

  sheet.merge_cells('A1:H2')

  sheet.add_row(
    [
      'Period',
      data['period'],
      'Generated at',
      data['generated_at'],
      nil,
      nil,
      nil,
      nil
    ],
    style: [
      styles[:header],
      styles[:cell],
      styles[:header],
      styles[:cell],
      nil,
      nil,
      nil,
      nil
    ]
  )

  sheet.add_row Array.new(8)

  approval_pct = value(data, 'status_summary', 'approved', 'share_pct')
  avg_latency  = value(data, 'latency', 'avg_sec')
  total_amount = data['total_amount']

  sheet.add_row(
    [
      'Operations', nil,
      'Approval rate', nil,
      'Avg latency', nil,
      'Total amount', nil
    ],
    style: Array.new(8, styles[:kpi_label]),
    height: 22
  )

  sheet.add_row(
    [
      data['total_operations'], nil,
      approval_pct, nil,
      avg_latency, nil,
      total_amount, nil
    ],
    style: Array.new(8, styles[:kpi_value]),
    height: 30
  )
  { 0 => '#,##0', 2 => '0.00\%', 4 => '0.00\ \s', 6 => '#,##0.00' }.each do |column, format|
    sheet.rows.last.cells[column].style = s.add_style(
      b: true, sz: 16, fg_color: 'FF1F4E78', border: border,
      alignment: { horizontal: :center, vertical: :center }, format_code: format
    )
  end

  [
    'A5:B5',
    'C5:D5',
    'E5:F5',
    'G5:H5',
    'A6:B6',
    'C6:D6',
    'E6:F6',
    'G6:H6'
  ].each do |range|
    sheet.merge_cells(range)
  end

  sheet.add_row Array.new(8)

  sheet.add_row(
    ['Traffic distribution: fact vs target'],
    style: styles[:section]
  )

  sheet.merge_cells('A8:D8')

  sheet.add_row(
    [
      'Provider',
      'Fact share %',
      'Target share %',
      'Deviation pp'
    ],
    style: styles[:header]
  )

  distribution_start = sheet.rows.size + 1

  data['distribution'].each do |provider, metrics|

    deviation = deviation(metrics)

    sheet.add_row(
      [
        provider,
        metrics['share_pct'],
        metrics['target_pct'],
        deviation
      ],
      style: [
        styles[:cell],
        styles[:percent_points],
        styles[:percent_points],
        styles[:decimal]
      ]
    )
  end

  distribution_end = sheet.rows.size

  if distribution_end >= distribution_start
  sheet.add_chart(
    Axlsx::BarChart,
    start_at: [5, 7],
    end_at: [12, 19],
    title: 'Traffic: Fact vs Target',
    show_legend: true
  ) do |chart|

    chart.bar_dir = :col
    chart.grouping = :clustered
    chart.legend_position = :b

    chart.add_series(
      data: sheet["B#{distribution_start}:B#{distribution_end}"],
      labels: sheet["A#{distribution_start}:A#{distribution_end}"],
      title: 'Fact %'
    )

    chart.add_series(
      data: sheet["C#{distribution_start}:C#{distribution_end}"],
      labels: sheet["A#{distribution_start}:A#{distribution_end}"],
      title: 'Target %'
    )
  end
  end

  sheet.add_row Array.new(8)

  utilization_title_row = sheet.rows.size + 1

  sheet.add_row(
    ['Daily limit utilization'],
    style: styles[:section]
  )

  sheet.merge_cells(
    "A#{utilization_title_row}:D#{utilization_title_row}"
  )

  sheet.add_row(
    [
      'Provider',
      'Used',
      'Limit',
      'Utilization %'
    ],
    style: styles[:header]
  )

  utilization_start = sheet.rows.size + 1

  data['projected_daily_utilization'].each do |provider, metrics|

    utilization = metrics['utilization_pct']

    utilization_style =
      if utilization.nil?
        styles[:muted]
      elsif utilization >= 95
        styles[:danger]
      elsif utilization >= 80
        styles[:warning]
      else
        styles[:good]
      end

    sheet.add_row(
      [
        provider,
        metrics['used'],
        metrics['limit'],
        utilization
      ],
      style: [
        styles[:cell],
        styles[:decimal],
        styles[:decimal],
        utilization_style
      ]
    )
  end

  utilization_end = sheet.rows.size

  if utilization_end >= utilization_start
  sheet.add_chart(
    Axlsx::BarChart,
    start_at: [5, 21],
    end_at: [12, 33],
    title: 'Daily Limit Utilization',
    show_legend: false
  ) do |chart|

    chart.bar_dir = :bar
    chart.grouping = :clustered

    chart.add_series(
      data: sheet["D#{utilization_start}:D#{utilization_end}"],
      labels: sheet["A#{utilization_start}:A#{utilization_end}"],
      title: 'Utilization %'
    )
  end
  end

  sheet.add_row Array.new(8)

  skip_title_row = sheet.rows.size + 1

  sheet.add_row(
    ['Provider skip reasons'],
    style: styles[:section]
  )

  sheet.merge_cells(
    "A#{skip_title_row}:D#{skip_title_row}"
  )

  sheet.add_row(
    ['Reason', 'Count'],
    style: styles[:header]
  )

  skip_start = sheet.rows.size + 1

  data['skip_reasons']
    .sort_by { |_reason, count| -safe_number(count) }
    .each do |reason, count|

      sheet.add_row(
        [reason, count],
        style: [
          styles[:cell],
          styles[:integer]
        ]
      )
    end

  skip_end = sheet.rows.size

  if skip_end >= skip_start
  sheet.add_chart(
    Axlsx::BarChart,
    start_at: [5, 35],
    end_at: [12, 47],
    title: 'Skip Reasons',
    show_legend: false
  ) do |chart|

    chart.bar_dir = :bar
    chart.grouping = :clustered

    chart.add_series(
      data: sheet["B#{skip_start}:B#{skip_end}"],
      labels: sheet["A#{skip_start}:A#{skip_end}"],
      title: 'Count'
    )
  end
  end

  sheet.column_widths(
    28,
    16,
    16,
    16,
    3,
    15,
    15,
    15
  )
end

# ============================================================
# 2. PROVIDERS
# ============================================================

workbook.add_worksheet(name: 'Providers') do |sheet|
  sheet.sheet_view.pane do |pane|
    pane.state = :frozen
    pane.y_split = 1
    pane.top_left_cell = 'A2'
  end

  headers = [
    'Provider',
    'Count',
    'Share %',
    'Target %',
    'Deviation pp',
    'Amount',
    'Volume share %',
    'Target volume %',
    'Approved',
    'Rejected',
    'Expired',
    'Approval rate %',
    'Avg latency',
    'P50 latency',
    'P95 latency',
    'Daily used',
    'Daily limit',
    'Daily utilization %',
    'Status',
    'Priority'
  ]

  sheet.add_row(
    headers,
    style: styles[:header],
    height: 32
  )

  data['distribution'].each do |provider, metrics|

    utilization =
      data.dig(
        'projected_daily_utilization',
        provider
      ) || {}

    provider_state =
      data.dig(
        'provider_state',
        provider
      ) || {}

    latency =
      metrics['latency'] || {}

    sheet.add_row(
      [
        provider,
        metrics['count'],
        metrics['share_pct'],
        metrics['target_pct'],
        deviation(metrics),
        metrics['amount'],
        metrics['volume_share_pct'],
        metrics['target_volume_share_pct'],
        metrics['approved'],
        metrics['rejected'],
        metrics['expired'],
        metrics['approval_rate_pct'],
        latency['avg_sec'],
        latency['p50_sec'],
        latency['p95_sec'],
        utilization['used'],
        utilization['limit'],
        utilization['utilization_pct'],
        provider_state['status'],
        provider_state['priority']
      ],

      style: [
        styles[:cell],
        styles[:integer],
        styles[:percent_points],
        styles[:percent_points],
        styles[:decimal],
        styles[:decimal],
        styles[:percent_points],
        styles[:percent_points],
        styles[:integer],
        styles[:integer],
        styles[:integer],
        styles[:percent_points],
        styles[:seconds],
        styles[:seconds],
        styles[:seconds],
        styles[:decimal],
        styles[:decimal],
        styles[:percent_points],
        styles[:cell_center],
        styles[:integer]
      ]
    )
  end

  sheet.column_widths(
    18,
    10,
    12,
    12,
    13,
    14,
    15,
    16,
    10,
    10,
    10,
    16,
    14,
    14,
    14,
    14,
    14,
    18,
    12,
    10
  )
end

# ============================================================
# 3. ROUTING
# ============================================================

workbook.add_worksheet(name: 'Routing') do |sheet|

  sheet.add_row(
    ['ROUTING / ATTEMPT ANALYTICS'],
    style: styles[:title],
    height: 26
  )

  sheet.merge_cells('A1:F1')

  sheet.add_row []

  attempts = data['attempt_cascades'] || {}

  sheet.add_row(
    ['Metric', 'Value'],
    style: styles[:header]
  )

  routing_metrics = [
    ['Operations with attempt logs', attempts['operations_with_attempt_logs']],
    ['Recorded attempts', attempts['recorded_attempts']],
    ['Average recorded attempts', attempts['average_recorded_attempts']],
    ['First-choice operations', attempts['first_choice_operations']],
    ['First-choice approval %', attempts['first_choice_approval_pct']],
    ['Fallback operations', attempts['fallback_operations']],
    ['Classification coverage %', attempts['classification_coverage_pct']]
  ]

  routing_metrics.each do |metric, metric_value|

    sheet.add_row(
      [metric, metric_value],
      style: [
        styles[:cell],
        styles[:cell_center]
      ]
    )
  end

  sheet.add_row []

  sheet.add_row(
    [
      'Attempts per operation',
      'Operations'
    ],
    style: styles[:header]
  )

  attempts_start = sheet.rows.size + 1

  (
    attempts['attempt_count_distribution'] || {}
  )
    .sort_by { |count, _| count.to_i }
    .each do |attempt_count, operations|

      sheet.add_row(
        [
          attempt_count.to_i,
          operations
        ],
        style: [
          styles[:integer],
          styles[:integer]
        ]
      )
    end

  attempts_end = sheet.rows.size

  if attempts_end >= attempts_start

    sheet.add_chart(
      Axlsx::BarChart,
      start_at: [3, 2],
      end_at: [10, 15],
      title: 'Attempt Count Distribution',
      show_legend: false
    ) do |chart|

      chart.bar_dir = :col
      chart.grouping = :clustered

      chart.add_series(
        data: sheet["B#{attempts_start}:B#{attempts_end}"],
        labels: sheet["A#{attempts_start}:A#{attempts_end}"],
        title: 'Operations'
      )
    end
  end

  sheet.add_row []

  sheet.add_row(
    ['Decision', 'Count'],
    style: styles[:header]
  )

  (
    attempts['attempt_decisions'] || {}
  ).each do |decision, count|

    sheet.add_row(
      [
        decision,
        count
      ],
      style: [
        styles[:cell],
        styles[:integer]
      ]
    )
  end

  sheet.add_row []

  sheet.add_row(
    ['Skip reason', 'Count'],
    style: styles[:header]
  )

  data['skip_reasons']
    .sort_by { |_reason, count| -safe_number(count) }
    .each do |reason, count|

      sheet.add_row(
        [reason, count],
        style: [
          styles[:cell],
          styles[:integer]
        ]
      )
    end

  sheet.column_widths(
    52,
    18,
    4,
    16,
    16,
    16
  )
end

# ============================================================
# 4. SEGMENTS
# ============================================================

workbook.add_worksheet(name: 'Segments') do |sheet|

  providers = data['distribution'].keys

  by_bank =
    data.dig(
      'segments',
      'by_bank'
    ) || {}

  by_amount =
    data.dig(
      'segments',
      'by_amount'
    ) || {}

  sheet.add_row(
    ['BANK × PROVIDER APPROVAL RATE'],
    style: styles[:title],
    height: 26
  )

  last_column =
    Axlsx.col_ref(providers.length + 2)

  sheet.merge_cells(
    "A1:#{last_column}1"
  )

  bank_headers = [
    'Bank',
    'Operations',
    'Overall approval %'
  ] + providers.map do |provider|
    "#{provider} approval %"
  end

  sheet.add_row(
    bank_headers,
    style: styles[:header],
    height: 32
  )

  by_bank.each do |bank, metrics|

    row_values = [
      bank,
      metrics['count'],
      metrics['approval_rate_pct']
    ]

    row_styles = [
      styles[:cell],
      styles[:integer],
      approval_style(
        metrics['approval_rate_pct'],
        styles
      )
    ]

    providers.each do |provider|

      rate =
        metrics.dig(
          'providers',
          provider,
          'approval_rate_pct'
        )

      row_values << rate

      row_styles <<
        approval_style(
          rate,
          styles
        )
    end

    sheet.add_row(
      row_values,
      style: row_styles
    )
  end

  sheet.add_row []

  title_row =
    sheet.rows.size + 1

  sheet.add_row(
    ['AMOUNT BAND × PROVIDER APPROVAL RATE'],
    style: styles[:section]
  )

  sheet.merge_cells(
    "A#{title_row}:#{last_column}#{title_row}"
  )

  amount_headers = [
    'Amount band',
    'Operations',
    'Overall approval %'
  ] + providers.map do |provider|
    "#{provider} approval %"
  end

  sheet.add_row(
    amount_headers,
    style: styles[:header],
    height: 32
  )

  by_amount.each do |band, metrics|

    row_values = [
      band,
      metrics['count'],
      metrics['approval_rate_pct']
    ]

    row_styles = [
      styles[:cell],
      styles[:integer],
      approval_style(
        metrics['approval_rate_pct'],
        styles
      )
    ]

    providers.each do |provider|

      rate =
        metrics.dig(
          'providers',
          provider,
          'approval_rate_pct'
        )

      row_values << rate

      row_styles <<
        approval_style(
          rate,
          styles
        )
    end

    sheet.add_row(
      row_values,
      style: row_styles
    )
  end

  widths =
    [20, 12, 18] +
    Array.new(
      providers.length,
      18
    )

  sheet.column_widths(*widths)
end

# ============================================================
# 5. PERIOD COMPARISON
# ============================================================

workbook.add_worksheet(name: 'Period Comparison') do |sheet|

  comparison = data['period_comparison'] || {}
  current    = comparison['current'] || {}
  previous   = comparison['previous'] || {}

  sheet.add_row(
    ['CURRENT vs PREVIOUS PERIOD'],
    style: styles[:title],
    height: 26
  )

  sheet.merge_cells('A1:F1')

  sheet.add_row []

  sheet.add_row(
    [
      'Metric',
      'Current',
      'Previous',
      'Delta'
    ],
    style: styles[:header]
  )

  comparison_rows = [
    [
      'Operations',
      current['count'],
      previous['count']
    ],
    [
      'Amount',
      current['amount'],
      previous['amount']
    ],
    [
      'Approval rate %',
      current['approval_rate_pct'],
      previous['approval_rate_pct']
    ],
    [
      'Avg latency sec',
      current.dig(
        'latency',
        'avg_sec'
      ),
      previous.dig(
        'latency',
        'avg_sec'
      )
    ]
  ]

  comparison_rows.each do |metric, current_value, previous_value|

    excel_row =
      sheet.rows.size + 1

    delta =
      if current_value.nil? || previous_value.nil?
        nil
      else
        "=B#{excel_row}-C#{excel_row}"
      end

    sheet.add_row(
      [
        metric,
        current_value,
        previous_value,
        delta
      ],
      style: [
        styles[:cell],
        styles[:decimal],
        styles[:decimal],
        styles[:decimal]
      ]
    )
    if delta
      sheet.rows.last.cells[3].escape_formulas = false
      sheet.rows.last.cells[3].formula_value = current_value - previous_value
    end
  end

  sheet.add_row []

  sheet.add_row(
    [
      'Provider',
      'Current share %',
      'Previous share %',
      'Share delta pp',
      'Current approval %',
      'Previous approval %'
    ],
    style: styles[:header]
  )

  current_providers =
    current['providers'] || {}

  previous_providers =
    previous['providers'] || {}

  provider_names =
    (
      current_providers.keys |
      previous_providers.keys
    ).sort

  provider_names.each do |provider|

    current_provider =
      current_providers[provider] || {}

    previous_provider =
      previous_providers[provider] || {}

    current_share =
      current_provider['share_pct']

    previous_share =
      previous_provider['share_pct']

    share_delta =
      if current_share && previous_share
        current_share - previous_share
      end

    sheet.add_row(
      [
        provider,
        current_share,
        previous_share,
        share_delta,
        current_provider[
          'approval_rate_pct'
        ],
        previous_provider[
          'approval_rate_pct'
        ]
      ],
      style: [
        styles[:cell],
        styles[:percent_points],
        styles[:percent_points],
        styles[:decimal],
        styles[:percent_points],
        styles[:percent_points]
      ]
    )
  end

  sheet.column_widths(
    24,
    18,
    18,
    18,
    20,
    20
  )

  # Keep the actual comparison windows visible; they differ from the full report period.
  sheet.add_row []
  sheet.add_row ['Period', 'From (inclusive)', 'To (exclusive)'], style: styles[:header]
  sheet.add_row ['Current', current['from_inclusive'], current['to_exclusive']], style: styles[:cell]
  sheet.add_row ['Previous', previous['from_inclusive'], previous['to_exclusive']], style: styles[:cell]
end

# ============================================================
# 6. RECOMMENDATIONS
# ============================================================

workbook.add_worksheet(name: 'Recommendations') do |sheet|

  sheet.add_row(
    ['ROUTING ENGINE RECOMMENDATIONS'],
    style: styles[:title],
    height: 26
  )

  sheet.merge_cells('A1:B1')

  sheet.add_row(
    [
      '#',
      'Recommendation'
    ],
    style: styles[:header]
  )

  data['recommendations']
    .each_with_index do |recommendation, index|

      sheet.add_row(
        [
          index + 1,
          recommendation
        ],
        style: [
          styles[:integer],
          styles[:recommendation]
        ],
        height: [[recommendation.lines.sum { |line| [(line.length / 100.0).ceil, 1].max } * 16 + 8, 38].max, 409].min
      )
    end

  sheet.column_widths(
    8,
    120
  )
  if data['recommendation_period']
    sheet.add_row []
    sheet.add_row ['Period', data['recommendation_period']], style: styles[:cell]
  end
end

# ============================================================
# Сохраняем Excel
# ============================================================

FileUtils.mkdir_p(File.dirname(output_path))
# Serialize first, then replace the destination; failures leave an existing report intact.
Tempfile.create(['routing_analytics', '.xlsx'], File.dirname(output_path)) do |temporary|
  temporary.close
  errors = package.validate
  raise ArgumentError, "Invalid XLSX workbook: #{errors.map(&:message).join('; ')}" unless errors.empty?
  package.serialize(temporary.path)
  File.rename(temporary.path, output_path)
end

puts
puts '------------------------------------------'
puts 'Excel report successfully created'
puts "Input:  #{input_path}"
puts "Output: #{output_path}"
puts '------------------------------------------'
rescue JSON::ParserError, OptionParser::ParseError, EncodingError, ArgumentError, SystemCallError, IOError => e
  warn "Excel report error: #{e.message}"
  exit 1
end
