require_relative "../../test_helper"
require_relative "../../support/seeded_database"
require_relative "../../../lib/routing_analytics"
require_relative "../../../lib/canonical_database_analytics"
require_relative "../../../lib/payment_routing/menu/app"
require "delegate"
require "digest"
require "tmpdir"
require "stringio"

module PaymentRouting
  module Menu
    class AppTest < Minitest::Test
      # Переопределяет один метод RoutingConfig, остальные делегирует реальному
      # экземпляру - тестам нужен свой, записываемый config-файл лишь для
      # одного из трёх (routing.yml/strategies.yml/business_parameters.yml).
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

      # Не Dir.mktmpdir с блоком: на Windows автоочистка иногда натыкается на
      # ещё не отпущенный ОС файловый хэндл SQLite сразу после disconnect
      # (не связано с GC/ссылками) - чистим сами и терпим один такой сбой.
      def with_app(config: RoutingConfig.new, **seed_options)
        dir = Dir.mktmpdir("menu-app-")
        path = SeededDatabase.seed(File.join(dir, "operations.db"), **seed_options)
        app = App.new(database_path: path, config: config)
        yield app, path
      ensure
        app&.instance_variable_get(:@db)&.disconnect
        begin
          FileUtils.remove_entry(dir, force: true) if dir
        rescue Errno::EACCES
          nil
        end
      end

      # Скармливает сценарий ввода приватному методу-экрану и возвращает то,
      # что было напечатано - реальный ввод/вывод меню без раскрутки
      # бесконечного App#run (выход из него - только Ctrl+C, по заданию).
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

      def test_start_route_runs_and_writes_the_decisions_file
        with_app do |app, _path|
          output = script(app, :start_route, [])
          assert_match(/decisions written/, output)
          assert File.file?(File.join(PaymentRouting.root, "routing_decisions_test.json"))
        end
      end

      def test_strategies_menu_toggles_a_strategy_on_and_back_off
        config = isolated_routing_config

        with_app(config: config) do |app, _path|
          before = YamlEditor.active_strategies(config.config_file)

          script(app, :strategies_menu, ["1", "x", ""])
          toggled_on = YamlEditor.active_strategies(config.config_file)
          refute_equal before, toggled_on

          script(app, :strategies_menu, ["1", "x", ""])
          assert_equal before, YamlEditor.active_strategies(config.config_file)
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

      def test_data_source_menu_update_reports_a_message
        with_app(providers: false, history: false) do |app, _path|
          output = script(app, :data_source_menu, ["1", "x", ""], :update)
          assert_match(/records added\/updated/, output)
        end
      end

      def test_toggle_clear_mode_restores_database_on_exit
        with_app do |app, path|
          before_hash = Digest::SHA256.file(path).hexdigest
          script(app, :toggle_clear_mode, ["x"])
          assert app.instance_variable_get(:@clear_mode)

          app.instance_variable_get(:@db)[:providers].where(payment_system: "vipay").update(traffic_percentage: 1)
          refute_equal before_hash, Digest::SHA256.file(path).hexdigest

          app.send(:restore_database_if_clear_mode!)
          assert_equal before_hash, Digest::SHA256.file(path).hexdigest
        end
      end

      def test_clear_mode_disabled_leaves_database_changes_in_place
        with_app do |app, path|
          before_hash = Digest::SHA256.file(path).hexdigest
          app.instance_variable_get(:@db)[:providers].where(payment_system: "vipay").update(traffic_percentage: 1)

          app.send(:restore_database_if_clear_mode!)

          refute_equal before_hash, Digest::SHA256.file(path).hexdigest
        end
      end
    end
  end
end
