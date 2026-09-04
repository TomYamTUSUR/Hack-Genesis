require "json"
require "yaml"

module PaymentRouting
  # Корень репозитория — от него разрешаются относительные пути в config/routing.yml.
  def self.root
    File.expand_path("..", __dir__)
  end
end

require_relative "payment_routing/constants"
require_relative "payment_routing/math_utils"
require_relative "payment_routing/routing_config"
require_relative "payment_routing/amount_range"
require_relative "payment_routing/provider"
require_relative "payment_routing/operation"
require_relative "payment_routing/operation_queue_loader"
require_relative "payment_routing/provider_actuals"
require_relative "payment_routing/provider_registry"
require_relative "payment_routing/historical_actuals_provider"
require_relative "payment_routing/reference_decisions"
require_relative "payment_routing/reference_decisions_loader"

require_relative "payment_routing/strategies/strategy_definition"
require_relative "payment_routing/strategies/strategy_registry"
require_relative "payment_routing/strategies/strategy_weight_calculator"

require_relative "payment_routing/rating/load_factor_calculator"
require_relative "payment_routing/rating/rating_pool"
require_relative "payment_routing/rating/norms/base_norm"
require_relative "payment_routing/rating/norms/count_share_norm"
require_relative "payment_routing/rating/norms/volume_share_norm"
require_relative "payment_routing/rating/norms/priority_norm"
require_relative "payment_routing/rating/norms/range_fit_norm"
require_relative "payment_routing/rating/norms/conversion_norm"
require_relative "payment_routing/rating/norms/intensity_norm"
require_relative "payment_routing/rating/norms/turnover_norm"
require_relative "payment_routing/rating/provider_score_calculator"
