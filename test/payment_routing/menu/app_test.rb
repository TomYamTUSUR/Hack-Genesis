require_relative "../../test_helper"
require_relative "../../support/seeded_database"
require_relative "../../../lib/routing_analytics"
require_relative "../../../lib/canonical_database_analytics"
require_relative "../../../lib/payment_routing/menu/app"
require "delegate"
require "tmpdir"
require "stringio"

module PaymentRouting
  module Menu
    class AppTest < Minitest::Test
      class ConfigOverride < SimpleDelegator
        def initialize(base, overrides)
          super(base)
          @overrides = overrides
        end

        def method_missing(name, *args, &block)
          @overrides.key?(name) ? @overrides.fetch(name) : super
        end

        def respond_to_missing?(name, include_private = false)
          @overrides.key?(name) || super
        end
      end

      def with_app(config: RoutingConfig.new, **seed_options)
        dir = Dir.mktmpdir("menu-app-")
        path = SeededDatabase.seed(File.join(dir, "operations.db"), **seed_options)
        app = App.new(database_path: path, config: config, output_dir: dir)
        yield app, path, dir
      ensure
        app&.instance_variable_get(:@db)&.disconnect
        begin
          FileUtils.remove_entry(dir, force: true) if dir
        rescue Errno::EACCES
          nil
        end
      end

      def script(app, screen, input_lines, *args)
        original_stdin = $stdin
        original_stdout = $stdout
        $stdin = StringIO.new(input_lines.join("\n") + "\n")
        $stdout = StringIO.new
        app.send(screen, *args)
        $stdout.string
      ensure
        $stdin = original_stdin
        $stdout = original_stdout
      end

      def isolated_routing_config
        dir = Dir.mktmpdir("routing-config-")
        routing_yml = File.join(dir, "routing.yml")
        FileUtils.cp(RoutingConfig::DEFAULT_CONFIG_FILE, routing_yml)
        RoutingConfig.new(config_file: routing_yml)
      end

      def test_start_route_reports_missing_prerequisites
        config = isolated_routing_config
        YamlEditor.active_strategies(config.config_file).each { |key| YamlEditor.toggle_active_strategy(config.config_file, key) }

        with_app(config: config, queue: false, history: false, providers: false) do |app, _path|
          output = script(app, :start_route, [])
          assert_match(/select at least one strategy/, output)
          assert_match(/no data in providers/, output)
          assert_match(/no data in operations_queue/, output)
          assert_match(/no data in operations_history/, output)
        end
      end

      def test_start_route_writes_both_the_decisions_and_the_report_file
        with_app do |app, _path, dir|
          output = script(app, :start_route, [])
          assert_match(/decisions written/, output)
          assert_match(/Report written to/, output)
          assert File.file?(File.join(dir, "routing_decisions_test.json"))
          assert File.file?(File.join(dir, "routing_report_test.json"))
        end
      end

      def test_strategies_menu_toggles_a_strategy_on_and_back_off
        config = isolated_routing_config

        with_app(config: config) do |app, _path|
          before = YamlEditor.active_strategies(config.config_file)

          script(app, :strategies_menu, ["1", "x", ""])
          toggled_on = YamlEditor.active_strategies(config.config_file)
          refute_equal before.sort, toggled_on.sort

          script(app, :strategies_menu, ["1", "x", ""])
          assert_equal before.sort, YamlEditor.active_strategies(config.config_file).sort
        end
      end

      def test_strategies_menu_toggles_several_strategies_from_one_input
        config = isolated_routing_config
        YamlEditor.active_strategies(config.config_file).each { |key| YamlEditor.toggle_active_strategy(config.config_file, key) }

        with_app(config: config) do |app, _path|
          keys = YamlEditor.combo_coefficients(config.strategies_file).keys
          output = script(app, :strategies_menu, ["1, 2", "x", ""])

          assert_equal [keys[0], keys[1]].sort, YamlEditor.active_strategies(config.config_file).sort
          assert_match(/Toggled: #{keys[0]}, #{keys[1]}/, output)
        end
      end

      def test_strategies_menu_reports_invalid_tokens_without_crashing
        config = isolated_routing_config

        with_app(config: config) do |app, _path|
          output = script(app, :strategies_menu, ["99, abc", "x", ""])
          assert_match(/Invalid: 99, abc/, output)
        end
      end

      def test_provider_metrics_menu_excludes_the_fallback_provider
        with_app do |app, _path|
          output = script(app, :provider_metrics_menu, [""])
          refute_match(/spacepayments/, output)
          assert_match(/vipay/, output)
        end
      end

      def test_provider_metrics_shows_business_parameters_immediately_on_first_open
        with_app do |app, _path|
          output = script(app, :provider_fields_menu, [""], "vipay")
          assert_match(/preferred_range_min: 50001/, output)
          assert_match(/volume_share_pct: 50/, output)
          assert_match(/requests_per_minute_limit: 20/, output)
        end
      end

      def test_provider_metrics_syncs_business_parameters_even_when_providers_load_after_app_start
        with_app(providers: false, queue: false, history: false) do |app, _path|
          data_source_menu_output = script(app, :data_source_menu, ["1", "x", ""], :update)
          assert_match(/records added\/updated/, data_source_menu_output)

          output = script(app, :provider_fields_menu, [""], "vipay")
          assert_match(/preferred_range_min: 50001/, output)
          assert_match(/volume_share_pct: 50/, output)
        end
      end

      def test_edit_provider_field_rejects_a_negative_value
        with_app do |app, _path|
          output = script(app, :provider_fields_menu, ["3", "-10", "x", ""], "vipay")
          assert_match(/must not be negative/, output)
          assert_equal 50.0, app.instance_variable_get(:@db)[:providers].where(payment_system: "vipay").get(:volume_share_pct)
        end
      end

      def test_edit_provider_field_rejects_a_percentage_above_100
        with_app do |app, _path|
          output = script(app, :provider_fields_menu, ["3", "150", "x", ""], "vipay")
          assert_match(/must not exceed 100/, output)
          assert_equal 50.0, app.instance_variable_get(:@db)[:providers].where(payment_system: "vipay").get(:volume_share_pct)
        end
      end

      def test_edit_provider_field_allows_a_negative_free_field_boundary_at_zero
        Dir.mktmpdir("business-parameters-") do |dir|
          business_parameters_yml = File.join(dir, "business_parameters.yml")
          File.write(business_parameters_yml, "providers:\n")
          config = ConfigOverride.new(RoutingConfig.new, business_parameters_file: business_parameters_yml)

          with_app(config: config) do |app, _path|
            script(app, :provider_fields_menu, ["4", "0", "x", ""], "vipay")
            assert_equal 0.0, app.instance_variable_get(:@db)[:providers].where(payment_system: "vipay").get(:requests_per_minute_limit)
          end
        end
      end

      def test_provider_fields_menu_writes_to_yaml_and_db
        Dir.mktmpdir("business-parameters-") do |dir|
          business_parameters_yml = File.join(dir, "business_parameters.yml")
          File.write(business_parameters_yml, "providers:\n")
          config = ConfigOverride.new(RoutingConfig.new, business_parameters_file: business_parameters_yml)

          with_app(config: config) do |app, _path|
            script(app, :provider_fields_menu, ["3", "42", "x", ""], "vipay")

            assert_equal 42.0, YamlEditor.business_parameters(business_parameters_yml)["vipay"]["volume_share_pct"]
            db = app.instance_variable_get(:@db)
            assert_equal 42.0, db[:providers].where(payment_system: "vipay").get(:volume_share_pct)
          end
        end
      end

      def test_edit_provider_field_clear_keyword_unsets_the_value_in_yaml_and_db
        Dir.mktmpdir("business-parameters-") do |dir|
          business_parameters_yml = File.join(dir, "business_parameters.yml")
          File.write(business_parameters_yml, "providers:\n  vipay:\n    volume_share_pct: 50\n")
          config = ConfigOverride.new(RoutingConfig.new, business_parameters_file: business_parameters_yml)

          with_app(config: config) do |app, _path|
            output = script(app, :provider_fields_menu, ["3", "clear", "x", ""], "vipay")

            assert_match(/volume_share_pct for vipay cleared \(not set\)/, output)
            assert_nil YamlEditor.business_parameters(business_parameters_yml)["vipay"]["volume_share_pct"]
            db = app.instance_variable_get(:@db)
            assert_nil db[:providers].where(payment_system: "vipay").get(:volume_share_pct)
          end
        end
      end

      def test_edit_provider_field_clear_keyword_is_case_insensitive
        Dir.mktmpdir("business-parameters-") do |dir|
          business_parameters_yml = File.join(dir, "business_parameters.yml")
          File.write(business_parameters_yml, "providers:\n  vipay:\n    volume_share_pct: 50\n")
          config = ConfigOverride.new(RoutingConfig.new, business_parameters_file: business_parameters_yml)

          with_app(config: config) do |app, _path|
            script(app, :provider_fields_menu, ["3", "CLEAR", "x", ""], "vipay")

            assert_nil YamlEditor.business_parameters(business_parameters_yml)["vipay"]["volume_share_pct"]
          end
        end
      end

      def test_data_source_menu_update_reports_a_message
        with_app(providers: false, history: false) do |app, _path|
          output = script(app, :data_source_menu, ["1", "x", ""], :update)
          assert_match(/records added\/updated/, output)
        end
      end

      def test_toggle_clear_mode_flips_the_flag_and_confirms
        with_app do |app, _path|
          output = script(app, :toggle_clear_mode, ["x"])
          assert app.instance_variable_get(:@clear_mode)
          assert_match(/Clear mode enabled/, output)
        end
      end

      def test_start_route_with_clear_mode_restores_original_data_right_after_processing
        with_app do |app, _path|
          app.instance_variable_set(:@clear_mode, true)
          db = app.instance_variable_get(:@db)
          original_daily_approved = db[:providers].where(payment_system: "vipay").get(:daily_approved_amount)

          output = script(app, :start_route, [])

          assert_match(/decisions written/, output)
          assert_match(/Report written to/, output)
          assert_match(/Clear mode: database restored to original data/, output)

          assert_equal 10, db[:operations_queue].count
          assert_equal 0, db[:routing_decisions].count
          assert_equal 0, db[:routing_attempts].count
          assert_equal 100, db[:operations_history].count
          assert_equal original_daily_approved, db[:providers].where(payment_system: "vipay").get(:daily_approved_amount)
        end
      end

      def test_start_route_without_clear_mode_leaves_processed_data_in_place
        with_app do |app, _path|
          db = app.instance_variable_get(:@db)

          script(app, :start_route, [])

          assert_equal 10, db[:routing_decisions].count
          assert_equal 110, db[:operations_history].count
        end
      end

      def test_generate_excel_report_blocks_without_a_report
        with_app do |app, _path|
          output = script(app, :generate_excel_report, [])
          assert_match(/routing_report_test\.json not found/, output)
        end
      end

      def test_generate_excel_report_writes_the_xlsx_file
        with_app do |app, _path, dir|
          script(app, :start_route, [])
          output = script(app, :generate_excel_report, [])
          assert_match(/Excel analytics report generated/, output)
          assert File.file?(File.join(dir, "routing_analytics.xlsx"))
        end
      end
    end
  end
end
