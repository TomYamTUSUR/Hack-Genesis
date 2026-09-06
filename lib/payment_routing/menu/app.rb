require "fileutils"
require "json"
require_relative "terminal"
require_relative "yaml_editor"
require_relative "data_manager"

module PaymentRouting
  module Menu
    # Интерактивное консольное меню поверх уже существующего движка - ничего
    # нового не считает, только вызывает готовые классы (RoutingRun,
    # CanonicalDatabaseAnalytics, Importers, YamlEditor) и показывает их
    # результат. Каждый экран - метод, читающий одну строку ввода за раз:
    # пустой ввод возвращает на экран выше (кроме главного меню - там no-op),
    # успешное действие (переключение/ввод значения) показывает сообщение и
    # возвращает на экран, с которого его вызвали (см. README/задание).
    class App
      # provider fields: label -> {key: колонка в providers, cast: приведение ввода}
      PROVIDER_FIELDS = [
        { key: :preferred_range_min, cast: :integer },
        { key: :preferred_range_max, cast: :integer },
        { key: :volume_share_pct, cast: :float },
        { key: :requests_per_minute_limit, cast: :float },
        { key: :daily_turnover_min, cast: :integer },
        { key: :daily_turnover_max, cast: :integer }
      ].freeze

      def initialize(database_path: Db::DEFAULT_PATH, config: RoutingConfig.new)
        @database_path = database_path
        @config = config
        @db = Db.connect(@database_path)
        Db.create_schema!(@db)
        @clear_mode = false
        @snapshot_path = snapshot_database!
        register_exit_hook
      end

      def run
        loop { main_menu }
      end

      private

      # ---------------------------------------------------------------- main

      def main_menu
        input = choose([
          "=== Smart Payment Routing ===",
          "",
          "1. Start Route",
          "2. Switch strategies",
          "3. Form report",
          "4. Data",
          "5. Provider metrics",
          "6. Strategies priority",
          "7. Clear mode [#{@clear_mode ? 'enabled' : 'disabled'}]"
        ])

        case input
        when "" then nil # главное меню: пустой ввод ничего не делает
        when "1" then start_route
        when "2" then strategies_menu
        when "3" then form_report
        when "4" then data_menu
        when "5" then provider_metrics_menu
        when "6" then strategies_priority_menu
        when "7" then toggle_clear_mode
        else invalid_choice
        end
      end

      # ------------------------------------------------------------ 1. route

      def start_route
        missing = start_route_blockers
        unless missing.empty?
          finish_with_message(["Route not started:", *missing.map { |line| "  - #{line}" }])
          return
        end

        result = RoutingRun.new(db: @db, database_path: @database_path, config: @config).call
        if result.processed
          output = File.join(PaymentRouting.root, "routing_decisions_test.json")
          File.write(output, JSON.pretty_generate(result.decisions) + "\n", encoding: "UTF-8")
          finish_with_message(["Done: #{result.decisions.size} decisions written to #{output}"])
        else
          finish_with_message(["No unprocessed operations in operations_queue"])
        end
      rescue StandardError => e
        finish_with_message(["Error running Route: #{e.message}"])
      end

      def start_route_blockers
        blockers = []
        blockers << "select at least one strategy (item 2 - Switch strategies)" if active_strategies.empty?
        blockers << "no data in providers - load it (item 4 - Data)" if @db[:providers].empty?
        blockers << "no data in operations_queue - load it (item 4 - Data)" if @db[:operations_queue].empty?
        blockers << "no data in operations_history - load it (item 4 - Data)" if @db[:operations_history].empty?
        blockers
      end

      # --------------------------------------------------------- 2. strategies

      def strategies_menu
        loop do
          keys = strategy_keys
          active = active_strategies
          lines = ["=== Switch strategies ==="] + keys.each_with_index.map do |key, index|
            mark = active.include?(key) ? "✅" : "❌"
            "#{index + 1}. #{key} #{mark}"
          end
          input = choose(lines)
          return if input.empty?

          index = input.to_i - 1
          if index.between?(0, keys.size - 1)
            YamlEditor.toggle_active_strategy(@config.config_file, keys[index])
            press_key("Strategy '#{keys[index]}' toggled.")
          else
            invalid_choice
          end
        end
      end

      # ------------------------------------------------------------ 3. report

      def form_report
        output = File.join(PaymentRouting.root, "routing_report_test.json")
        analytics = RoutingAnalytics::CanonicalDatabaseAnalytics.new(@database_path)
        RoutingAnalytics::ReportWriter.write(output, analytics.report)
        analytics.close
        finish_with_message(["Report written to #{output}"])
      rescue StandardError => e
        finish_with_message(["Error building report: #{e.message}"])
      end

      # ------------------------------------------------------------- 4. data

      def data_menu
        loop do
          input = choose(["=== Data ===", "", "1. Update", "2. Replace", "3. Clear"])
          return if input.empty?

          case input
          when "1" then data_source_menu(:update)
          when "2" then data_source_menu(:replace)
          when "3"
            message = data_manager.clear_all!
            press_key(message)
          else invalid_choice
          end
        end
      end

      def data_source_menu(action)
        loop do
          sources = data_manager.sources
          lines = ["=== Data / #{action == :update ? 'Update' : 'Replace'} ==="] +
                  sources.each_with_index.map { |source, index| "#{index + 1}. #{source.label}" } +
                  ["#{sources.size + 1}. All"]
          input = choose(lines)
          return if input.empty?

          index = input.to_i - 1
          if index == sources.size
            messages = sources.map { |source| data_manager.public_send(action, source.key) }
            press_key(messages.join("\n"))
          elsif index.between?(0, sources.size - 1)
            press_key(data_manager.public_send(action, sources[index].key))
          else
            invalid_choice
          end
        end
      end

      def data_manager
        @data_manager ||= DataManager.new(db: @db, config: @config)
      end

      # ------------------------------------------------------- 5. providers

      def provider_metrics_menu
        loop do
          names = @db[:providers].order(:payment_system).select_map(:payment_system)
          if names.empty?
            finish_with_message(["No providers in the database - load data first (item 4 - Data)"])
            return
          end

          lines = ["=== Provider metrics ==="] + names.each_with_index.map { |name, index| "#{index + 1}. #{name}" }
          input = choose(lines)
          return if input.empty?

          index = input.to_i - 1
          if index.between?(0, names.size - 1)
            provider_fields_menu(names[index])
          else
            invalid_choice
          end
        end
      end

      def provider_fields_menu(payment_system)
        loop do
          row = @db[:providers].where(payment_system: payment_system).first
          lines = ["=== Provider metrics / #{payment_system} ==="] + PROVIDER_FIELDS.each_with_index.map do |field, index|
            value = row[field[:key]]
            "#{index + 1}. #{field[:key]}: #{value.nil? ? '(not set)' : value}"
          end
          input = choose(lines)
          return if input.empty?

          index = input.to_i - 1
          if index.between?(0, PROVIDER_FIELDS.size - 1)
            edit_provider_field(payment_system, PROVIDER_FIELDS[index])
          else
            invalid_choice
          end
        end
      end

      def edit_provider_field(payment_system, field)
        print "New value for #{field[:key]} (Enter - back): "
        input = Terminal.read_line
        return if input.empty?

        value = cast_number(input, field[:cast])
        if value.nil?
          press_key("Error: '#{input}' is not a number")
          return
        end

        YamlEditor.set_business_parameter(@config.business_parameters_file, payment_system, field[:key].to_s, value)
        Importers::BusinessParametersImporter.new(db: @db, business_parameters_file: @config.business_parameters_file).import
        press_key("#{field[:key]} for #{payment_system} updated: #{value}")
      end

      # -------------------------------------------------- 6. strategies priority

      def strategies_priority_menu
        loop do
          coefficients = YamlEditor.combo_coefficients(@config.strategies_file)
          keys = coefficients.keys
          lines = ["=== Strategies priority ==="] + keys.each_with_index.map do |key, index|
            "#{index + 1}. #{key}: #{coefficients[key]}"
          end
          input = choose(lines)
          return if input.empty?

          index = input.to_i - 1
          if index.between?(0, keys.size - 1)
            edit_combo_coefficient(keys[index])
          else
            invalid_choice
          end
        end
      end

      def edit_combo_coefficient(key)
        print "New combo_coefficient value for #{key} (Enter - back): "
        input = Terminal.read_line
        return if input.empty?

        value = cast_number(input, :float)
        if value.nil?
          press_key("Error: '#{input}' is not a number")
          return
        end

        YamlEditor.set_combo_coefficient(@config.strategies_file, key, value)
        press_key("combo_coefficient for #{key} updated: #{value}")
      end

      # --------------------------------------------------------- 7. clear mode

      def toggle_clear_mode
        @clear_mode = !@clear_mode
        press_key("Clear mode #{@clear_mode ? 'enabled' : 'disabled'}.")
      end

      # ------------------------------------------------------------- helpers

      def active_strategies
        YamlEditor.active_strategies(@config.config_file)
      end

      def strategy_keys
        YamlEditor.combo_coefficients(@config.strategies_file).keys
      end

      def cast_number(input, cast)
        cast == :integer ? Integer(input) : Float(input)
      rescue ArgumentError
        nil
      end

      def choose(lines)
        Terminal.clear_screen
        lines.each { |line| Terminal.puts(line) }
        Terminal.puts
        print "Enter item number (Enter - back): "
        Terminal.read_line
      end

      def invalid_choice
        press_key("Invalid input.")
      end

      def press_key(message)
        Terminal.clear_screen
        Terminal.puts(message)
        Terminal.press_any_key
      end

      # Экраны без вложенных списков (Start Route/Form report) после сообщения
      # возвращаются сразу в главное меню - у них нет промежуточного уровня.
      def finish_with_message(lines)
        Terminal.clear_screen
        lines.each { |line| Terminal.puts(line) }
        Terminal.press_any_key
      end

      # ------------------------------------------------------------ clear mode

      def snapshot_database!
        return nil unless File.file?(@database_path)

        path = "#{@database_path}.menu_snapshot"
        FileUtils.cp(@database_path, path)
        path
      end

      def register_exit_hook
        at_exit { restore_database_if_clear_mode! }
      end

      def restore_database_if_clear_mode!
        if @clear_mode && @snapshot_path && File.file?(@snapshot_path)
          @db.disconnect
          FileUtils.cp(@snapshot_path, @database_path)
          Kernel.puts "Clear mode: database restored to session-start state"
        end
        File.delete(@snapshot_path) if @snapshot_path && File.file?(@snapshot_path)
      end
    end
  end
end
