require "yaml"

module PaymentRouting
  module Importers
    # Дополняет уже существующие строки providers полями, которых нет в
    # data/providers.json (preferred_range_min/max, volume_share_pct,
    # requests_per_minute_limit, daily_turnover_min/max) - значениями из
    # config/business_parameters.yml. Только UPDATE, не upsert: провайдер
    # должен быть уже создан ProvidersImporter'ом.
    class BusinessParametersImporter
      def initialize(db:, business_parameters_file:)
        @db = db
        @business_parameters_file = business_parameters_file
      end

      def import
        providers = YAML.safe_load(File.read(@business_parameters_file))["providers"]
        providers.each { |payment_system, attrs| update_provider(payment_system, attrs) }
        providers.size
      end

      private

      def update_provider(payment_system, attrs)
        updated = @db[:providers].where(payment_system: payment_system).update(attrs.transform_keys(&:to_sym))
        return unless updated.zero?

        raise "Провайдер '#{payment_system}' из #{@business_parameters_file} не найден в providers - сначала импортируйте providers"
      end
    end
  end
end
