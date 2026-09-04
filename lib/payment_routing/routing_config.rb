module PaymentRouting
  # Единственное место, которое знает про config/routing.yml.
  # providers_file/operations_history_file/operations_queue_file нужны только
  # bin/import_data.rb (первичная загрузка data/* в БД) - рейтинг и стратегии
  # их не используют, они читают только db/operations.db.
  class RoutingConfig
    DEFAULT_CONFIG_FILE = File.join(PaymentRouting.root, "config", "routing.yml")

    def initialize(config_file: DEFAULT_CONFIG_FILE)
      @raw = YAML.safe_load(File.read(config_file))
    end

    def providers_file
      resolve(@raw["data"]["providers_file"])
    end

    def operations_history_file
      resolve(@raw["data"]["operations_history_file"])
    end

    def operations_queue_file
      resolve(@raw["data"]["operations_queue_file"])
    end

    def strategies_file
      resolve(@raw["strategies_file"])
    end

    def active_strategies
      @raw["active_strategies"].map(&:to_sym)
    end

    def rated_providers
      @raw["rated_providers"]
    end

    private

    def resolve(relative_path)
      File.join(PaymentRouting.root, relative_path)
    end
  end
end
