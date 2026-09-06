require "io/console"

module PaymentRouting
  module Menu
    # Ввод/вывод консольного меню
    module Terminal
      module_function

      def clear_screen
        return unless $stdout.tty?

        system("cls") || system("clear")
      end

      def puts(text = "")
        Kernel.puts(text)
      end

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
