require_relative "../../test_helper"
require_relative "../../../lib/payment_routing/menu/yaml_editor"
require "tmpdir"

module PaymentRouting
  module Menu
    class YamlEditorTest < Minitest::Test
      def with_file(content)
        Dir.mktmpdir do |dir|
          path = File.join(dir, "config.yml")
          File.write(path, content)
          yield path
        end
      end

      ROUTING_YML = <<~YAML
        # comment above
        data:
          providers_file: data/providers.json

        active_strategies:
          - priority

        rated_providers:
          - vipay
      YAML

      def test_toggle_active_strategy_adds_a_new_key_and_preserves_comments
        with_file(ROUTING_YML) do |path|
          updated = YamlEditor.toggle_active_strategy(path, "conversion")

          assert_equal %w[priority conversion], updated
          content = File.read(path)
          assert_includes content, "# comment above"
          assert_includes content, "rated_providers:\n  - vipay"
        end
      end

      def test_toggle_active_strategy_removes_an_existing_key
        with_file(ROUTING_YML) do |path|
          updated = YamlEditor.toggle_active_strategy(path, "priority")

          assert_empty updated
          assert_equal [], YamlEditor.active_strategies(path)
        end
      end

      def test_active_strategies_reads_current_list
        with_file(ROUTING_YML) { |path| assert_equal ["priority"], YamlEditor.active_strategies(path) }
      end

      STRATEGIES_YML = <<~YAML
        # explains combo mode
        strategies:
          - key: count_share
            combo_coefficient: 1.0
          - key: priority
            combo_coefficient: 1.6
      YAML

      def test_set_combo_coefficient_updates_only_the_matching_strategy
        with_file(STRATEGIES_YML) do |path|
          YamlEditor.set_combo_coefficient(path, "priority", 2.5)

          coefficients = YamlEditor.combo_coefficients(path)
          assert_equal 2.5, coefficients["priority"]
          assert_equal 1.0, coefficients["count_share"]
          assert_includes File.read(path), "# explains combo mode"
        end
      end

      BUSINESS_PARAMETERS_YML = <<~YAML
        # business params
        providers:
          vipay:
            preferred_range_min: 50001
            volume_share_pct: 50
      YAML

      def test_set_business_parameter_updates_an_existing_field
        with_file(BUSINESS_PARAMETERS_YML) do |path|
          YamlEditor.set_business_parameter(path, "vipay", "volume_share_pct", 60)

          assert_equal 60, YamlEditor.business_parameters(path)["vipay"]["volume_share_pct"]
          assert_equal 50001, YamlEditor.business_parameters(path)["vipay"]["preferred_range_min"]
        end
      end

      def test_set_business_parameter_adds_a_new_field_to_an_existing_provider
        with_file(BUSINESS_PARAMETERS_YML) do |path|
          YamlEditor.set_business_parameter(path, "vipay", "requests_per_minute_limit", 20)

          assert_equal 20, YamlEditor.business_parameters(path)["vipay"]["requests_per_minute_limit"]
        end
      end

      def test_set_business_parameter_adds_a_brand_new_provider_block
        with_file(BUSINESS_PARAMETERS_YML) do |path|
          YamlEditor.set_business_parameter(path, "quickpay", "volume_share_pct", 25)

          assert_equal 25, YamlEditor.business_parameters(path)["quickpay"]["volume_share_pct"]
          assert_equal 50, YamlEditor.business_parameters(path)["vipay"]["volume_share_pct"]
        end
      end
    end
  end
end
