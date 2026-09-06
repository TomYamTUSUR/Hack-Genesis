# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'
require 'tmpdir'
require 'zip'
require 'nokogiri'
require_relative '../lib/excel_report_input'

class ExcelReportTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SCRIPT = File.join(ROOT, 'bin/generate_excel_report.rb')

  def minimal_report
    { 'period' => nil, 'total_operations' => 0, 'distribution' => {},
      'skip_reasons' => {}, 'projected_daily_utilization' => {}, 'recommendations' => [] }
  end

  def export(data)
    Dir.mktmpdir('excel-report') do |directory|
      input = File.join(directory, 'input.json')
      output = File.join(directory, 'nested', 'report.xlsx')
      File.write(input, JSON.generate(data), encoding: 'UTF-8')
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, input, output)
      assert status.success?, "#{stdout}\n#{stderr}"
      Zip::File.open(output) { |zip| yield zip }
    end
  end

  def xml(zip, name)
    Nokogiri::XML(zip.read(name)) { |config| config.strict }.remove_namespaces!
  end

  def test_real_analyzer_report_exports_six_sheets_and_working_cached_formulas
    data = JSON.parse(File.read(File.join(ROOT, 'routing_report_test.json')))
    export(data) do |zip|
      workbook = xml(zip, 'xl/workbook.xml')
      assert_equal ['Dashboard', 'Providers', 'Routing', 'Segments', 'Period Comparison', 'Recommendations'],
                   workbook.xpath('//sheet/@name').map(&:value)
      dashboard = xml(zip, 'xl/worksheets/sheet1.xml')
      assert_equal data['total_operations'], dashboard.at_xpath('//c[@r="A6"]/v').text.to_i
      comparison = xml(zip, 'xl/worksheets/sheet5.xml')
      assert_equal 'B4-C4', comparison.at_xpath('//c[@r="D4"]/f').text
      assert_equal data.dig('period_comparison', 'current', 'count') - data.dig('period_comparison', 'previous', 'count'),
                   comparison.at_xpath('//c[@r="D4"]/v').text.to_i
      assert_equal 4, zip.entries.count { |entry| entry.name.match?(%r{\Axl/charts/chart\d+\.xml\z}) }
    end
  end

  def test_empty_data_has_no_invalid_chart_ranges
    export(minimal_report) do |zip|
      assert_empty zip.entries.select { |entry| entry.name.start_with?('xl/charts/') }
      assert_equal 'A1:C1', xml(zip, 'xl/worksheets/sheet4.xml').at_xpath('//mergeCell/@ref').value
    end
  end

  def test_many_providers_and_missing_deviations
    data = minimal_report
    data['distribution'] = (1..30).to_h { |i| ["provider#{i}", { 'share_pct' => 3.5 }] }
    data['distribution']['provider2']['target_pct'] = 2
    export(data) do |zip|
      assert_equal 'A1:AG1', xml(zip, 'xl/worksheets/sheet4.xml').at_xpath('//mergeCell/@ref').value
      providers = xml(zip, 'xl/worksheets/sheet2.xml')
      assert_nil providers.at_xpath('//c[@r="E2"]/v')
      assert_equal 1.5, providers.at_xpath('//c[@r="E3"]/v').text.to_f
      dashboard = xml(zip, 'xl/worksheets/sheet1.xml')
      assert_nil dashboard.at_xpath('//c[@r="D10"]/v')
      assert_equal 1.5, dashboard.at_xpath('//c[@r="D11"]/v').text.to_f
    end
  end

  def test_input_strings_are_not_excel_formulas
    data = minimal_report
    data['recommendations'] = ['=1+1']
    data['distribution'] = { '=1+1' => {} }
    export(data) do |zip|
      %w[sheet1 sheet2 sheet6].each do |sheet|
        assert_empty xml(zip, "xl/worksheets/#{sheet}.xml").xpath('//f')
      end
      assert_includes xml(zip, 'xl/worksheets/sheet6.xml').text, '=1+1'
    end
  end

  def test_malformed_types_fail_with_field_paths
    [[], minimal_report.merge('distribution' => []),
     minimal_report.merge('distribution' => { 'vipay' => { 'share_pct' => 'oops' } }),
     minimal_report.merge('segments' => { 'by_bank' => { 'bank' => nil } }),
     minimal_report.merge('attempt_cascades' => { 'attempt_count_distribution' => { 'oops' => 1 } })].each do |data|
      assert_raises(ArgumentError) { RoutingAnalytics::ExcelReportInput.validate!(data) }
    end
  end

  def test_cli_errors_preserve_existing_output_and_help_needs_no_input
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, '--help')
    assert status.success?, stderr
    assert_includes stdout, 'Usage:'
    assert_includes stdout, 'Default input: routing_report_test.json'
    Dir.mktmpdir('excel-error') do |directory|
      input = File.join(directory, 'invalid.json')
      output = File.join(directory, 'report.xlsx')
      File.write(input, '{broken')
      File.write(output, 'existing report')
      _, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, input, output)
      refute status.success?
      assert_includes stderr, 'Excel report error:'
      assert_equal 'existing report', File.read(output)
    end
  end

  def test_bom_input_default_output_and_replacing_existing_report
    Dir.mktmpdir('excel-bom') do |directory|
      input = File.join(directory, 'analytics.json')
      output = File.join(directory, 'routing_analytics.xlsx')
      File.binwrite(input, "\xEF\xBB\xBF".b + JSON.generate(minimal_report).b)
      File.write(output, 'old report')
      _, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, input, chdir: directory)
      assert status.success?, stderr
      Zip::File.open(output) { |zip| assert zip.find_entry('xl/workbook.xml') }
    end
  end

  def test_missing_input_and_extra_arguments_are_reported_without_backtraces
    Dir.mktmpdir('excel-args') do |directory|
      [[File.join(directory, 'missing.json')], %w[a b c], ['--unknown']].each do |arguments|
        _, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, *arguments)
        refute status.success?
        assert_includes stderr, 'Excel report error:'
        refute_includes stderr, '<main>'
      end
    end
  end
end
