module PaymentRouting
  # Восстанавливает итоговый JSON решений (формат из ТЗ - operation_id,
  # selected_provider, attempts[], simulated_result, latency_sec) из БД
  # (routing_decisions + routing_attempts), а не из Router'а в памяти.
  # Тот же принцип, что и у RoutingAnalytics::CanonicalDatabaseAnalytics для
  # routing_report_test.json: bin/route.rb только считает и пишет в БД через
  # RoutingAnalytics::DatabaseWriter#log_operations, а этот класс - единственный
  # путь превратить содержимое БД обратно в JSON нужного формата.
  class DecisionsReader
    def initialize(db:)
      @db = db
    end

    def load
      operation_ids = @db[:operations_queue].select(:operation_id, :created_at).all
        .sort_by { |row| [row[:created_at], row[:operation_id]] }.map { |row| row[:operation_id] }
      decisions_by_id = decisions_by_operation_id
      attempts_by_id = attempts_by_operation_id

      operation_ids.map do |operation_id|
        decision = decisions_by_id.fetch(operation_id) do
          raise "Нет routing_decisions для #{operation_id} - запустите bin/route.rb перед bin/build_decisions.rb"
        end

        result = {
          "operation_id" => operation_id,
          "selected_provider" => decision.fetch(:selected_provider),
          "attempts" => attempts_by_id.fetch(operation_id, []),
          "simulated_result" => decision.fetch(:simulated_result),
          "latency_sec" => decision.fetch(:latency_sec)
        }
        result["explanation"] = JSON.parse(decision[:explanation]) if decision[:explanation]
        result
      end
    end

    private

    def decisions_by_operation_id
      @db[:routing_decisions]
        .join(:providers, payment_system_id: :selected_payment_system_id)
        .select_all(:routing_decisions)
        .select_append(Sequel[:providers][:payment_system].as(:selected_provider))
        .to_hash(:operation_id)
    end

    # attempt_number хранит исходный порядок попыток Router'а - без него
    # порядок строк из БД не гарантирован.
    def attempts_by_operation_id
      @db[:routing_attempts]
        .join(:providers, payment_system_id: :payment_system_id)
        .order(Sequel[:routing_attempts][:operation_id], Sequel[:routing_attempts][:attempt_number])
        .select_all(:routing_attempts)
        .select_append(Sequel[:providers][:payment_system].as(:provider))
        .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |row, memo|
          attempt = { "provider" => row[:provider], "decision" => row[:decision], "reason" => row[:reason] }
          attempt["details"] = JSON.parse(row[:details]) if row[:details]
          attempt["dispatched_at"] = row[:dispatched_at].iso8601(6) if row[:dispatched_at]
          memo[row[:operation_id]] << attempt
        end
    end
  end
end
