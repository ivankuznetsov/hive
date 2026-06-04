require "json"
require "time"
require "hive/commands/status"
require "hive/config"

module Hive
  module Web
    class StatusFeed
      def initialize(interval: 1.0, status_command: Hive::Commands::Status.new(json: true))
        @interval = interval
        @status_command = status_command
      end

      def snapshot
        @status_command.json_payload(Hive::Config.registered_projects)
      end

      # The dedup cursor is local to each call, so every `/events`
      # subscriber tracks its own "last seen" snapshot. A shared instance
      # cursor would split changes across concurrent connections and starve
      # a freshly connected client of the emit-on-connect snapshot until the
      # next change. Starting from `nil` guarantees the first iteration
      # always yields (emit on connect).
      def each_snapshot
        last_json = nil
        loop do
          payload = snapshot
          encoded = JSON.generate(payload)
          if encoded != last_json
            last_json = encoded
            yield payload
          end
          sleep @interval
        end
      end
    end
  end
end
