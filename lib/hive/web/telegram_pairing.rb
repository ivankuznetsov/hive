require "stringio"

require "hive/commands/pairing"

module Hive
  module Web
    # Browser adapter for the owner-side pairing command. The command keeps
    # the resolve -> allowlist/notice -> consume transaction authoritative;
    # this class only suppresses CLI rendering and exposes its JSON list shape.
    class TelegramPairing
      def initialize(command_class: Hive::Commands::Pairing)
        @command_class = command_class
      end

      def pending
        @command_class.new("list", json: true, output: StringIO.new).call.fetch("pending")
      rescue KeyError, NoMethodError, TypeError
        raise Hive::Error, "could not read pending Telegram pairings — run `hive pairing list` for details"
      end

      def approve(code)
        @command_class.new(
          "approve",
          args: [ "telegram", code.to_s ],
          json: true,
          output: StringIO.new
        ).call
      end
    end
  end
end
