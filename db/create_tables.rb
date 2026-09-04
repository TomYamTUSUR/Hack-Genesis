require_relative 'database'

db = PaymentRouting::Db.connect
PaymentRouting::Db.create_schema!(db)

puts "OK"
puts "Созданные таблицы: #{db.tables.join(', ')}"
