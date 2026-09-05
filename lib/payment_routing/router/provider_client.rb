module PaymentRouting
  module Router
    # Единственная точка, через которую Router "обращается" к провайдеру.
    # v1 всегда успешна - на тестовых данных симулировать технический отказ
    # (не hard-constraint, а сбой именно в момент обращения) нет смысла, но
    # сам механизм перехода к следующему кандидату (см. Router#route) обязан
    # существовать и быть проверяемым - тестовый ProviderClient форсирует
    # UnavailableError, не трогая эту реализацию.
    #
    # Реальный сценарий "у провайдера упал сервер" в проект ляжет не сюда, а
    # через providers.status: провайдера переводят в status: "inactive", и его
    # уже исключает существующий HardFilter::Rules::StatusRule на следующей
    # операции - без изменений в ProviderClient/Router. Периодический
    # health-check, возвращающий status обратно в "active", - отдельная,
    # пока не реализованная задача.
    class ProviderClient
      class UnavailableError < StandardError; end

      def attempt(provider:, operation:)
        nil
      end
    end
  end
end
