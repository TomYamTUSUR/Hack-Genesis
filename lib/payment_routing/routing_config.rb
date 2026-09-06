module PaymentRouting
  #Работа с конфигом
  class RoutingConfig
    DEFAULT_CONFIG_FILE = File.join(PaymentRouting.root, "config", "routing.yml")

    attr_reader :config_file

    def initialize(config_file: DEFAULT_CONFIG_FILE)
      @config_file = config_file
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

    def business_parameters_file
      resolve(@raw["data"]["business_parameters_file"])
    end

    def active_strategies
      @raw["active_strategies"].map(&:to_sym)
    end

    def rated_providers
      @raw["rated_providers"]
    end

    def fallback_provider
      @raw["fallback_provider"]
    end

    private

    def resolve(relative_path)
      File.join(PaymentRouting.root, relative_path)
    end
  end
end
