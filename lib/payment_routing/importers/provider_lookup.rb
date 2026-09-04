module PaymentRouting
  module Importers
    # Общий для history/reference импортёров способ превратить строковое имя
    # платёжной системы в payment_system_id из уже импортированной providers.
    module ProviderLookup
      def provider_id_for(db, payment_system)
        row = db[:providers].where(payment_system: payment_system).first
        raise "Провайдер '#{payment_system}' не найден в providers - импортируйте providers первым" unless row

        row[:payment_system_id]
      end
    end
  end
end
