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

require_relative "payment_routing/hard_filter/rules/base_rule"
require_relative "payment_routing/hard_filter/rules/status_rule"
require_relative "payment_routing/hard_filter/rules/amount_range_rule"
require_relative "payment_routing/hard_filter/rules/daily_amount_limit_rule"
require_relative "payment_routing/hard_filter/rules/in_progress_rule"
require_relative "payment_routing/hard_filter/rules/bank_rule"
require_relative "payment_routing/hard_filter/rules/margin_rule"
require_relative "payment_routing/hard_filter/rules/requisites_rule"
require_relative "payment_routing/hard_filter/rules/intensity_rule"
require_relative "payment_routing/hard_filter/rules/turnover_max_rule"
require_relative "payment_routing/hard_filter/result"
require_relative "payment_routing/hard_filter/engine"

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

require_relative "payment_routing/router/provider_client"
require_relative "payment_routing/router/outcome_simulator"
require_relative "payment_routing/router/run_state"
require_relative "payment_routing/router/metrics_updater"
require_relative "payment_routing/router/state_writer"
require_relative "payment_routing/router/decision"
require_relative "payment_routing/router/router"
