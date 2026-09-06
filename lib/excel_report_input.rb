# frozen_string_literal: true

module RoutingAnalytics
  # Validate only fields consumed by the Excel exporter. Unknown report fields
  # remain compatible with future Analyzer versions; nil metrics stay unknown.
  module ExcelReportInput
    module_function

    LATENCY = %w[avg_sec p50_sec p95_sec].to_h { |key| [key, :number] }.freeze
    PROVIDER = %w[count share_pct target_pct deviation_pp amount volume_share_pct
                  target_volume_share_pct approved rejected expired approval_rate_pct]
      .to_h { |key| [key, :number] }.merge('latency' => LATENCY).freeze
    PERIOD = {
      'count' => :number, 'amount' => :number, 'approval_rate_pct' => :number,
      'latency' => LATENCY, 'providers' => [:map, PROVIDER],
      'from_inclusive' => :text, 'to_exclusive' => :text
    }.freeze
    SEGMENT = {
      'count' => :number, 'approval_rate_pct' => :number,
      'providers' => [:map, { 'approval_rate_pct' => :number }]
    }.freeze
    REQUIRED = %w[period total_operations distribution skip_reasons projected_daily_utilization recommendations].freeze
    SCHEMA = {
      'period' => :text, 'generated_at' => :text, 'total_operations' => :number,
      'total_amount' => :number, 'recommendation_period' => :text,
      'distribution' => [:map, PROVIDER],
      'skip_reasons' => [:map, :number],
      'projected_daily_utilization' => [:map, {
        'used' => :number, 'limit' => :number, 'utilization_pct' => :number
      }],
      'recommendations' => [:array, :text],
      'provider_state' => [:map, { 'status' => :text, 'priority' => :number }],
      'latency' => LATENCY,
      'status_summary' => [:map, { 'share_pct' => :number }],
      'attempt_cascades' => {
        **%w[operations_with_attempt_logs recorded_attempts average_recorded_attempts
             first_choice_operations first_choice_approval_pct fallback_operations
             classification_coverage_pct].to_h { |key| [key, :number] },
        'attempt_count_distribution' => [:map, :number],
        'attempt_decisions' => [:map, :number]
      },
      'segments' => { 'by_bank' => [:map, SEGMENT], 'by_amount' => [:map, SEGMENT] },
      'period_comparison' => { 'current' => PERIOD, 'previous' => PERIOD }
    }.freeze

    def validate!(data)
      expect!(data.is_a?(Hash), '$', 'a JSON object')
      REQUIRED.each do |key|
        expect!(data.key?(key), key, 'present')
        expect!(!data[key].nil?, key, 'non-null') unless key == 'period'
      end
      validate_value!(data, SCHEMA, '$')
      attempts = data.dig('attempt_cascades', 'attempt_count_distribution') || {}
      attempts.each_key do |key|
        expect!(key.match?(/\A(?:0|[1-9]\d*)\z/), "attempt_count_distribution.#{key}", 'a non-negative integer key')
      end
      data
    end

    def validate_value!(value, schema, path)
      return if value.nil?

      case schema
      when Hash
        expect!(value.is_a?(Hash), path, 'an object')
        schema.each { |key, child| validate_value!(value[key], child, "#{path}.#{key}") }
      when Array
        kind, child = schema
        expect!(value.is_a?(kind == :map ? Hash : Array), path, kind == :map ? 'an object' : 'an array')
        entries = kind == :map ? value : value.each_with_index.map { |item, index| [index, item] }
        entries.each do |key, item|
          # Map records cannot be null: the exporter accesses their fields.
          expect!(!item.nil?, "#{path}.#{key}", 'non-null')
          validate_value!(item, child, "#{path}.#{key}")
        end
      when :number
        expect!(value.is_a?(Numeric) && value.finite?, path, 'a finite JSON number')
      when :text
        expect!(value.is_a?(String), path, 'a string')
      end
    end

    def expect!(condition, path, description)
      raise ArgumentError, "#{path} must be #{description}" unless condition
    end
  end
end
