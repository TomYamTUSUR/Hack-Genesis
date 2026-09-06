require "io/console"

module PaymentRouting
  module Menu
    # Ввод/вывод консольного меню в одном месте - остальной код меню не знает
    # про gets/print напрямую.
    module Terminal
      module_function

      def clear_screen
        return unless $stdout.tty?

        system("cls") || system("clear")
      end

      def puts(text = "")
        Kernel.puts(text)
      end

      # nil на EOF (закрытый stdin) - обрабатывается как пустой ввод (возврат назад).
      def read_line
        line = $stdin.gets
        line&.strip || ""
      end

      def press_any_key(message = "Press any key to return...")
        Kernel.puts(message)
        if $stdin.respond_to?(:getch) && $stdin.tty?
          $stdin.getch
        else
          $stdin.gets
        end
      end
    end
  end
end
