require_relative "../../test_helper"
require "tmpdir"

module PaymentRouting
  module Importers
    class BusinessParametersImporterTest < Minitest::Test
      def setup
        @db = Db.connect(nil)
        Db.create_schema!(@db)
        @db[:providers].insert(payment_system: "vipay", status: "active", traffic_percentage: 40, priority: 1)
        @db[:providers].insert(payment_system: "payflow", status: "active", traffic_percentage: 35, priority: 2)
        @db[:providers].insert(payment_system: "spacepayments", status: "active", traffic_percentage: 0, priority: 99)
      end

      def import(yaml_content)
        Dir.mktmpdir do |dir|
          path = File.join(dir, "business_parameters.yml")
          File.write(path, yaml_content)
          return BusinessParametersImporter.new(db: @db, business_parameters_file: path).import
        end
      end

      def test_applies_yaml_values_to_matching_db_providers
        count = import(<<~YAML)
          providers:
            vipay:
              volume_share_pct: 50
              requests_per_minute_limit: 20
        YAML

        assert_equal 1, count
        row = @db[:providers].where(payment_system: "vipay").first
        assert_equal 50.0, row[:volume_share_pct]
        assert_equal 20.0, row[:requests_per_minute_limit]
      end

      # Список, который реально трогается, берётся из providers (БД), а не из
      # ключей YAML - провайдер из БД без записи в YAML просто не изменяется.
      def test_leaves_db_providers_without_a_yaml_entry_untouched
        import(<<~YAML)
          providers:
            vipay:
              volume_share_pct: 50
        YAML

        row = @db[:providers].where(payment_system: "spacepayments").first
        assert_nil row[:volume_share_pct]
      end

      def test_raises_when_yaml_references_a_provider_not_in_the_db
        error = assert_raises(RuntimeError) do
          import(<<~YAML)
            providers:
              quickpay:
                volume_share_pct: 25
          YAML
        end

        assert_match(/quickpay/, error.message)
      end
    end
  end
end
