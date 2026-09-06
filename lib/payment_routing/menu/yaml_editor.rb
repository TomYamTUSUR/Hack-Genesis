require "yaml"

module PaymentRouting
  module Menu
    module YamlEditor
      module_function

      def active_strategies(routing_yml_path)
        YAML.safe_load(File.read(routing_yml_path))["active_strategies"] || []
      end

      def toggle_active_strategy(routing_yml_path, key)
        lines = File.readlines(routing_yml_path)
        start_index = lines.index { |line| line.start_with?("active_strategies:") }
        raise "active_strategies not found in #{routing_yml_path}" unless start_index

        end_index = start_index + 1
        end_index += 1 while end_index < lines.size && lines[end_index].start_with?("  - ")
        current = lines[(start_index + 1)...end_index].map { |line| line.sub("  - ", "").strip }

        updated = current.include?(key) ? current - [key] : current + [key]
        lines[(start_index + 1)...end_index] = updated.map { |item| "  - #{item}\n" }
        File.write(routing_yml_path, lines.join)
        updated
      end

      def combo_coefficients(strategies_yml_path)
        YAML.safe_load(File.read(strategies_yml_path))["strategies"].to_h { |row| [row["key"], row["combo_coefficient"]] }
      end

      def set_combo_coefficient(strategies_yml_path, key, value)
        lines = File.readlines(strategies_yml_path)
        key_index = lines.index { |line| line.strip == "- key: #{key}" }
        raise "Strategy '#{key}' not found in #{strategies_yml_path}" unless key_index

        coefficient_index = (key_index + 1...lines.size).find { |i| lines[i].include?("combo_coefficient:") }
        raise "combo_coefficient for '#{key}' not found in #{strategies_yml_path}" unless coefficient_index

        indent = lines[coefficient_index][/\A[ ]*/]
        lines[coefficient_index] = "#{indent}combo_coefficient: #{value}\n"
        File.write(strategies_yml_path, lines.join)
      end

      def business_parameters(business_parameters_yml_path)
        YAML.safe_load(File.read(business_parameters_yml_path))["providers"] || {}
      end

      def set_business_parameter(business_parameters_yml_path, provider, field, value)
        lines = File.readlines(business_parameters_yml_path)
        raise "providers not found in #{business_parameters_yml_path}" unless lines.any? { |line| line.start_with?("providers:") }

        provider_index = lines.index { |line| line.strip == "#{provider}:" }
        if provider_index
          block_end = (provider_index + 1...lines.size).find { |i| !lines[i].start_with?("    ") } || lines.size
          field_index = (provider_index + 1...block_end).find { |i| lines[i].strip.start_with?("#{field}:") }
          if field_index
            lines[field_index] = "    #{field}: #{value}\n"
          else
            lines.insert(block_end, "    #{field}: #{value}\n")
          end
        else
          lines << "  #{provider}:\n" << "    #{field}: #{value}\n"
        end
        File.write(business_parameters_yml_path, lines.join)
      end
    end
  end
end
