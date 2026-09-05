module PaymentRouting
  module Router
    # Изменяемое между операциями одного прогона состояние очереди - обёртка
    # над Provider/ProviderActuals по payment_system. Provider/ProviderActuals
    # сами неизменяемы (как и весь остальной проект): MetricsUpdater кладёт
    # сюда НОВЫЕ экземпляры (см. Provider#with/ProviderActuals#with), а не
    # мутирует существующие - так следующая операция в этой же очереди видит
    # уже изменившуюся картину, а не статичный снимок на начало прогона.
    class RunState
      def initialize(providers:, actuals_by_provider:)
        @providers_by_name = providers.to_h { |provider| [provider.payment_system, provider] }
        @actuals_by_name = actuals_by_provider.dup
      end

      def provider(payment_system)
        @providers_by_name.fetch(payment_system)
      end

      def providers
        @providers_by_name.values
      end

      def actuals(payment_system)
        @actuals_by_name.fetch(payment_system)
      end

      def actuals_by_provider
        @actuals_by_name
      end

      def replace_provider(provider)
        @providers_by_name[provider.payment_system] = provider
      end

      def replace_actuals(payment_system, actuals)
        @actuals_by_name[payment_system] = actuals
      end
    end
  end
end
