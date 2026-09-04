require_relative "../../test_helper"

module PaymentRouting
  module Importers
    class ProvidersImporterTest < Minitest::Test
      def setup
        @db = Db.connect(nil)
        Db.create_schema!(@db)
        @importer = ProvidersImporter.new(db: @db, providers_file: RoutingConfig.new.providers_file)
      end

      def test_imports_every_provider_from_the_data_file
        count = @importer.import

        assert_equal 4, count
        assert_equal 4, @db[:providers].count
      end

      def test_serializes_banks_as_a_json_array
        @importer.import

        vipay = @db[:providers].where(payment_system: "vipay").first
        assert_equal %w[sberbank tinkoff vtb], JSON.parse(vipay[:banks])
      end

      def test_reimporting_updates_in_place_without_touching_fields_absent_from_the_file
        @importer.import
        @db[:providers].where(payment_system: "vipay").update(volume_share_pct: 50)

        @importer.import

        assert_equal 1, @db[:providers].where(payment_system: "vipay").count
        assert_in_delta 50, @db[:providers].where(payment_system: "vipay").first[:volume_share_pct]
      end
    end
  end
end
