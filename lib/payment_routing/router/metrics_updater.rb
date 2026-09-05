module PaymentRouting
  module Router
    # Обновляет RunState выбранного провайдера сразу после решения по одной
    # операции - следующая операция той же очереди должна видеть уже
    # изменившуюся картину, а не статичный снимок истории на начало прогона.
    # Provider/ProviderActuals неизменяемы - в state кладутся новые экземпляры
    # (Provider#with/ProviderActuals#with), не мутация.
    #
    # count_share_actual/volume_share_actual - доли от ОБЩЕГО количества/объёма
    # по всем рейтингуемым провайдерам, поэтому один одобренный платёж сдвигает
    # долю не только у выбранного провайдера, а у всех сразу (меняется
    # знаменатель) - см. recalculate_shares!. rated_payment_systems передаётся
    # отдельно от provider, т.к. выбранным может быть fallback-провайдер, не
    # входящий в рейтинг (тогда пересчёт долей не нужен вовсе).
    class MetricsUpdater
      def apply(state:, provider:, operation:, simulated_result:, rated_payment_systems:)
        state.replace_provider(updated_provider(provider, operation, simulated_result))
        state.replace_actuals(provider.payment_system, updated_actuals(state.actuals(provider.payment_system), operation, simulated_result))
        recalculate_shares!(state, rated_payment_systems) if approved?(simulated_result) && rated_payment_systems.include?(provider.payment_system)
      end

      private

      def updated_provider(provider, operation, simulated_result)
        overrides = {
          in_progress_count: provider.in_progress_count + 1,
          in_progress_amount: provider.in_progress_amount + operation.amount
        }
        overrides[:daily_approved_amount] = provider.daily_approved_amount + operation.amount if approved?(simulated_result)
        provider.with(**overrides)
      end

      def updated_actuals(actuals, operation, simulated_result)
        return actuals unless approved?(simulated_result)

        actuals.with(
          turnover_actual: actuals.turnover_actual + operation.amount,
          count_actual: actuals.count_actual + 1,
          volume_actual: actuals.volume_actual + operation.amount
        )
      end

      # Пересчитывает count_share_actual/volume_share_actual КАЖДОГО
      # рейтингуемого провайдера от новых общих итогов - не только у
      # выбранного, доля остальных тоже сместилась из-за изменения знаменателя.
      def recalculate_shares!(state, rated_payment_systems)
        actuals_by_name = rated_payment_systems.to_h { |name| [name, state.actuals(name)] }
        total_count = actuals_by_name.values.sum(&:count_actual)
        total_volume = actuals_by_name.values.sum(&:volume_actual)

        actuals_by_name.each do |name, actuals|
          state.replace_actuals(name, actuals.with(
            count_share_actual: MathUtils.percentage_of(actuals.count_actual, total_count),
            volume_share_actual: MathUtils.percentage_of(actuals.volume_actual, total_volume)
          ))
        end
      end

      def approved?(simulated_result)
        simulated_result == OutcomeSimulator::APPROVED
      end
    end
  end
end
