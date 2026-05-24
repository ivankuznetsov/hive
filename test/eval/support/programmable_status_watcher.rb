require "hive/bot/status_watcher"

module Hive
  module Eval
    class ProgrammableStatusWatcher
      def initialize
        @queued = []
      end

      def queue(rows:)
        @queued << rows
      end

      def fetch
        Hive::Bot::StatusWatcher::Result.new(ok: true, rows: @queued.shift || [], error: nil)
      end
    end
  end
end
