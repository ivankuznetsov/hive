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
        @last_json = nil
      end

      def snapshot
        @status_command.json_payload(Hive::Config.registered_projects)
      end

      def each_snapshot
        loop do
          payload = snapshot
          encoded = JSON.generate(payload)
          if encoded != @last_json
            @last_json = encoded
            yield payload
          end
          sleep @interval
        end
      end
    end
  end
end
