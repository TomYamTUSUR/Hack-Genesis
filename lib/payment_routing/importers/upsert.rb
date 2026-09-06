module PaymentRouting
  module Importers
    #Обновление БД без дубликатов
    module Upsert
      module_function

      def by_key(table, key_column, key_value, attrs)
        scope = table.where(key_column => key_value)
        scope.empty? ? table.insert(attrs) : scope.update(attrs)
      end
    end
  end
end
