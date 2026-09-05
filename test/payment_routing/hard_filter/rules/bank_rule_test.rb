require_relative "../../../test_helper"

module PaymentRouting
  module HardFilter
    module Rules
      class BankRuleTest < Minitest::Test
        include TestFactories

        def test_empty_banks_list_means_no_restriction
          p = provider(banks: [], exclude_banks: false)

          assert_nil BankRule.new.call(provider: p, operation: operation(bank: "anything"), actuals: actuals)
        end

        def test_whitelist_passes_a_listed_bank
          p = provider(banks: %w[sberbank tinkoff], exclude_banks: false)

          assert_nil BankRule.new.call(provider: p, operation: operation(bank: "sberbank"), actuals: actuals)
        end

        def test_whitelist_excludes_an_unlisted_bank
          p = provider(banks: %w[sberbank tinkoff], exclude_banks: false)

          result = BankRule.new.call(provider: p, operation: operation(bank: "vtb"), actuals: actuals)

          assert_equal "bank_not_allowed", result
        end

        def test_blacklist_excludes_a_listed_bank
          p = provider(banks: %w[vtb], exclude_banks: true)

          result = BankRule.new.call(provider: p, operation: operation(bank: "vtb"), actuals: actuals)

          assert_equal "bank_not_allowed", result
        end

        def test_blacklist_passes_an_unlisted_bank
          p = provider(banks: %w[vtb], exclude_banks: true)

          assert_nil BankRule.new.call(provider: p, operation: operation(bank: "sberbank"), actuals: actuals)
        end
      end
    end
  end
end
