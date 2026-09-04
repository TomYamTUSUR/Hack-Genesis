module PaymentRouting
  module Importers
    # Insert-or-update по естественному ключу записи (payment_system,
    # operation_id, ...) - общая логика для всех *_importer.rb, чтобы повторный
    # запуск импорта обновлял существующие строки, а не плодил дубликаты или
    # не терял autoincrement id (как случилось бы с "INSERT OR REPLACE" для
    # providers - там ключ не совпадает с primary key).
    module Upsert
      module_function

      def by_key(table, key_column, key_value, attrs)
        scope = table.where(key_column => key_value)
        scope.empty? ? table.insert(attrs) : scope.update(attrs)
      end
    end
  end
end
