module PaymentRouting
  # Единственное место, которое знает, где на диске лежат входные данные и
  # конфиги (config/routing.yml). ProviderRegistry/HistoricalActualsProvider/etc
  # принимают уже разрешённые пути и сами про routing.yml не знают.
  class RoutingConfig
    DEFAULT_CONFIG_FILE = File.join(PaymentRouting.root, "config", "routing.yml")

    def initialize(config_file: DEFAULT_CONFIG_FILE)
      @raw = YAML.safe_load(File.read(config_file))
    end

    def providers_file
      resolve(@raw["data"]["providers_file"])
    end

    def providers_overlay_file
      resolve(@raw["data"]["providers_overlay_file"])
    end

    def operations_history_file
      resolve(@raw["data"]["operations_history_file"])
    end

    def operations_queue_file
      resolve(@raw["data"]["operations_queue_file"])
    end

    def reference_decisions_file
      resolve(@raw["data"]["reference_decisions_file"])
    end

    def strategies_file
      resolve(@raw["strategies_file"])
    end

    def active_strategies
      @raw["active_strategies"].map(&:to_sym)
    end

    private

    def resolve(relative_path)
      File.join(PaymentRouting.root, relative_path)
    end
  end
end
