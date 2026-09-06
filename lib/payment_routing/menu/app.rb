require "json"
require "open3"
require "rbconfig"
require_relative "terminal"
require_relative "yaml_editor"
require_relative "data_manager"

module PaymentRouting
  module Menu
    # Интерактивное консольное меню
    class App
      PROVIDER_FIELDS = [
        { key: :preferred_range_min, cast: :integer },
        { key: :preferred_range_max, cast: :integer },
        { key: :volume_share_pct, cast: :float, percentage: true },
        { key: :requests_per_minute_limit, cast: :float },
        { key: :daily_turnover_min, cast: :integer },
        { key: :daily_turnover_max, cast: :integer }
      ].freeze

      CLEAR_KEYWORD = "clear"

      def initialize(database_path: Db::DEFAULT_PATH, config: RoutingConfig.new)
        @database_path = database_path
        @config = config
        @db = Db.connect(@database_path)
        Db.create_schema!(@db)
        @clear_mode = false
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
          "2. Data",
          "3. Switch strategies",
          "4. Provider metrics",
          "5. Strategies priority",
          "6. Form excel analytics",
          "7. Clear mode [#{@clear_mode ? 'enabled' : 'disabled'}]"
        ])

        case input
        when "" then nil # главное меню: пустой ввод ничего не делает
        when "1" then start_route
        when "2" then data_menu
        when "3" then strategies_menu
        when "4" then provider_metrics_menu
        when "5" then strategies_priority_menu
        when "6" then generate_excel_report
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
        unless result.processed
          finish_with_message(["No unprocessed operations in operations_queue"])
          return
        end

        messages = [write_decisions(result.decisions), write_report]
        messages.concat(clear_mode_messages) if @clear_mode
        finish_with_message(messages)
      rescue StandardError => e
        finish_with_message(["Error running Route: #{e.message}"])
      end

      def write_decisions(decisions)
        output = File.join(PaymentRouting.root, "routing_decisions_test.json")
        File.write(output, JSON.pretty_generate(decisions) + "\n", encoding: "UTF-8")
        "Done: #{decisions.size} decisions written to #{output}"
      end

      def write_report
        output = File.join(PaymentRouting.root, "routing_report_test.json")
        analytics = RoutingAnalytics::CanonicalDatabaseAnalytics.new(@database_path)
        RoutingAnalytics::ReportWriter.write(output, analytics.report)
        analytics.close
        "Report written to #{output}"
      end

      def start_route_blockers
        blockers = []
        blockers << "select at least one strategy (item 3 - Switch strategies)" if active_strategies.empty?
        blockers << "no data in providers - load it (item 2 - Data)" if @db[:providers].empty?
        blockers << "no data in operations_queue - load it (item 2 - Data)" if @db[:operations_queue].empty?
        blockers << "no data in operations_history - load it (item 2 - Data)" if @db[:operations_history].empty?
        blockers
      end

      # --------------------------------------------------------- 3. strategies

      def strategies_menu
        loop do
          keys = strategy_keys
          active = active_strategies
          lines = ["=== Switch strategies ==="] + keys.each_with_index.map do |key, index|
            # [x]/[ ] вместо emoji - plain ASCII, корректно отображается на
            # любом устройстве/шрифте, в отличие от Unicode-галочек/крестиков.
            mark = active.include?(key) ? "[x]" : "[ ]"
            "#{index + 1}. #{key} #{mark}"
          end
          lines << "" << "Enter one or more numbers separated by spaces/commas to toggle several at once."
          input = choose(lines)
          return if input.empty?

          toggle_strategies(input, keys)
        end
      end

      def toggle_strategies(input, keys)
        toggled = []
        invalid = []
        input.split(/[\s,]+/).reject(&:empty?).each do |token|
          index = token.to_i - 1
          if token.match?(/\A\d+\z/) && index.between?(0, keys.size - 1)
            YamlEditor.toggle_active_strategy(@config.config_file, keys[index])
            toggled << keys[index]
          else
            invalid << token
          end
        end

        message = []
        message << "Toggled: #{toggled.join(', ')}" unless toggled.empty?
        message << "Invalid: #{invalid.join(', ')}" unless invalid.empty?
        press_key(message.empty? ? "No valid items selected." : message.join("\n"))
      end

      # ------------------------------------------------------------- 2. data

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

      # ------------------------------------------------------- 4. providers

      def provider_metrics_menu
        loop do
          names = @db[:providers].order(:payment_system).select_map(:payment_system) - [@config.fallback_provider]
          if names.empty?
            finish_with_message(["No providers in the database - load data first (item 2 - Data)"])
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
        sync_business_parameters!

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
        print "New value for #{field[:key]} (Enter - back, '#{CLEAR_KEYWORD}' - unset): "
        input = Terminal.read_line
        return if input.empty?

        if input.strip.casecmp(CLEAR_KEYWORD).zero?
          apply_business_parameter(payment_system, field, nil)
          press_key("#{field[:key]} for #{payment_system} cleared (not set)")
          return
        end

        value = cast_number(input, field[:cast])
        if value.nil?
          press_key("Error: '#{input}' is not a number")
          return
        end
        if value.negative?
          press_key("Error: value must not be negative")
          return
        end
        if field[:percentage] && value > 100
          press_key("Error: value must not exceed 100 (it's a percentage)")
          return
        end

        apply_business_parameter(payment_system, field, value)
        press_key("#{field[:key]} for #{payment_system} updated: #{value}")
      end

      def apply_business_parameter(payment_system, field, value)
        YamlEditor.set_business_parameter(@config.business_parameters_file, payment_system, field[:key].to_s, value)
        Importers::BusinessParametersImporter.new(db: @db, business_parameters_file: @config.business_parameters_file).import
      end

      # -------------------------------------------------- 5. strategies priority

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

      # -------------------------------------------------- 6. excel analytics

      def generate_excel_report
        report_path = File.join(PaymentRouting.root, "routing_report_test.json")
        unless File.file?(report_path)
          finish_with_message(["routing_report_test.json not found - run Start Route first (item 1)"])
          return
        end

        script = File.join(PaymentRouting.root, "bin", "generate_excel_report.rb")
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, script)
        if status.success?
          finish_with_message(["Excel analytics report generated.", *stdout.strip.lines.map(&:chomp)])
        else
          finish_with_message(["Error generating Excel report:", *stderr.strip.lines.map(&:chomp)])
        end
      end

      # --------------------------------------------------------- 7. clear mode

      def toggle_clear_mode
        @clear_mode = !@clear_mode
        press_key("Clear mode #{@clear_mode ? 'enabled' : 'disabled'}.")
      end

      def clear_mode_messages
        errors = [
          data_manager.clear_all!,
          data_manager.update("providers"),
          restore_business_parameters,
          data_manager.update("queue"),
          data_manager.update("history")
        ].compact.select { |message| message.start_with?("Error") }

        return ["Clear mode: database restored to original data"] if errors.empty?

        ["Clear mode: restore encountered errors:"] + errors.map { |error| "  - #{error}" }
      end

      def restore_business_parameters
        Importers::BusinessParametersImporter.new(db: @db, business_parameters_file: @config.business_parameters_file).import
        nil
      rescue StandardError => e
        "Error: #{e.message}"
      end

      # ------------------------------------------------------------- helpers

      def sync_business_parameters!
        return if @db[:providers].empty?

        Importers::BusinessParametersImporter.new(db: @db, business_parameters_file: @config.business_parameters_file).import
      end

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

      def finish_with_message(lines)
        Terminal.clear_screen
        lines.each { |line| Terminal.puts(line) }
        Terminal.press_any_key
      end
    end
  end
end
