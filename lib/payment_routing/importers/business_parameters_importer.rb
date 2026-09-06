require "yaml"

module PaymentRouting
  module Importers
    # Дополняет уже существующие строки providers полями, которых нет в
    # data/providers.json (preferred_range_min/max, volume_share_pct,
    # requests_per_minute_limit, daily_turnover_min/max) - значениями из
    # config/business_parameters.yml. Список провайдеров, которых касается
    # обновление, берётся из БД (providers уже должна быть заполнена
    # ProvidersImporter'ом) - YAML лишь поставляет значения для части из них.
    # Провайдер из providers без записи в YAML просто не трогается (поля
    # остаются как есть, обычно nil); имя в YAML, которого нет в providers -
    # ошибка (опечатка или забыли импортировать providers), не молчаливый no-op.
    class BusinessParametersImporter
      def initialize(db:, business_parameters_file:)
        @db = db
        @business_parameters_file = business_parameters_file
      end

      def import
        parameters_by_provider = YAML.safe_load(File.read(@business_parameters_file))["providers"] || {}
        known_providers = @db[:providers].select_map(:payment_system)

        unknown = parameters_by_provider.keys - known_providers
        unless unknown.empty?
          raise "#{@business_parameters_file}: провайдер(ы) #{unknown.join(', ')} не найдены в providers - сначала импортируйте providers"
        end

        updated_providers = known_providers.select do |payment_system|
          attrs = parameters_by_provider[payment_system]
          next false unless attrs

          @db[:providers].where(payment_system: payment_system).update(attrs.transform_keys(&:to_sym))
          true
        end

        updated_providers.size
      end
    end
  end
end
