require "securerandom"
require "time"
require "hive/stringify_keys"

module Hive
  module TaskJournal
    module Envelope
      SCHEMA = "hive-task-journal-event".freeze
      SCHEMA_VERSION = 1

      module_function

      def observational(slug:, stage:, event_type:, agent:, message:, at: Time.now.utc)
        {
          "ts" => at.utc.iso8601,
          "slug" => slug.to_s,
          "stage" => stage.to_s,
          "agent" => agent.nil? ? nil : agent.to_s,
          "event_type" => event_type.to_s,
          "message" => message
        }
      end

      def authoritative(attributes, id_generator: -> { SecureRandom.uuid }, clock: -> { Time.now.utc })
        input = Hive::StringifyKeys.call(attributes)
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "event_id" => input.delete("event_id") || id_generator.call,
          "event_type" => input.delete("event_type"),
          "occurred_at" => input.delete("occurred_at") || clock.call.utc.iso8601(6),
          "observed_at" => input.delete("observed_at"),
          "task" => input.delete("task"),
          "workflow" => input.delete("workflow"),
          "stage" => input.delete("stage"),
          "attempt_id" => input.delete("attempt_id"),
          "task_generation" => input.delete("task_generation"),
          "ownership_generation" => input.delete("ownership_generation"),
          "commit_generation" => input.delete("commit_generation"),
          "reason" => input.delete("reason"),
          "evidence" => input.delete("evidence") || [],
          "provenance" => input.delete("provenance") || {},
          "payload" => (input.delete("payload") || {}).merge(input)
        }
      end
    end
  end
end
