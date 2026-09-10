require "hive/errors"

module Hive
  # Durable, host-global daily activity projection. Task journals and other
  # project-local stores remain authoritative; this namespace owns the compact
  # cross-project day record and its append-only history.
  module DailyDigest
    class Error < Hive::Error; end
    class InvalidRecord < Error
      def exit_code = Hive::ExitCodes::USAGE
    end
    class MissingRecord < Error
      def exit_code = Hive::ExitCodes::UNAVAILABLE
    end
    class PrunedRecord < Error
      def exit_code = Hive::ExitCodes::UNAVAILABLE
    end
  end
end
