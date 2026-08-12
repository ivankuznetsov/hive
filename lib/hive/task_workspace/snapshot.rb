require "json"
require "time"

module Hive
  module TaskWorkspace
    class Snapshot
      attr_reader :data

      def initialize(generated_at:, task:, status:, decision:, panels:, limits: Limits.new)
        @limits = limits
        @data = TaskWorkspace.canonical(
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "generated_at" => normalize_time(generated_at),
          "task" => normalize_task(task),
          "status" => normalize_status(status),
          "decision" => normalize_decision(decision),
          "panels" => normalize_panels(panels)
        )
        TaskWorkspace.safe_value!(@data)
        if to_json.bytesize > @limits.fetch(:workspace_bytes)
          raise ArgumentError, "workspace snapshot exceeds workspace_bytes limit"
        end
      end

      def [](key)
        data[key.to_s]
      end

      def to_h
        JSON.parse(to_json)
      end

      def to_json(*_args)
        TaskWorkspace.canonical_json(data)
      end

      private

      def normalize_time(value)
        Time.iso8601(value.to_s).utc.iso8601(6)
      rescue ArgumentError
        raise ArgumentError, "invalid workspace snapshot timestamp"
      end

      def normalize_task(value)
        task = value.to_h.transform_keys(&:to_s)
        {
          "project" => required_string(task, "project"),
          "slug" => required_string(task, "slug"),
          "id" => task["id"],
          "stage" => required_string(task, "stage"),
          "generation" => task["generation"]
        }
      end

      def normalize_status(value)
        status = value.to_h.transform_keys(&:to_s)
        state = status.fetch("state").to_s
        freshness = status.fetch("freshness").to_s
        raise ArgumentError, "invalid workspace status state" unless STATES.include?(state)
        raise ArgumentError, "invalid workspace freshness" unless FRESHNESS_STATES.include?(freshness)

        {
          "state" => state,
          "freshness" => freshness,
          "observed_at" => status["observed_at"] && normalize_time(status["observed_at"]),
          "diagnostics" => Array(status["diagnostics"])
        }
      end

      def normalize_decision(value)
        decision = value.to_h.transform_keys(&:to_s)
        posture = decision.fetch("posture").to_s
        raise ArgumentError, "invalid workspace decision posture" unless POSTURES.include?(posture)

        action = decision.fetch("action", {}).to_h.transform_keys(&:to_s)
        {
          "posture" => posture,
          "reason" => decision["reason"]&.to_s,
          "action" => {
            "kind" => action["kind"]&.to_s,
            "label" => action["label"]&.to_s,
            "enabled" => action["enabled"] == true,
            "reason" => action["reason"]&.to_s
          }
        }
      end

      def normalize_panels(values)
        supplied = values.to_h.transform_keys(&:to_s)
        unknown = supplied.keys - PANEL_NAMES
        raise ArgumentError, "unknown workspace panels: #{unknown.join(', ')}" if unknown.any?

        PANEL_NAMES.to_h do |name|
          [ name, TaskWorkspace.normalize_panel(name, supplied[name]) ]
        end
      end

      def required_string(hash, key)
        value = hash.fetch(key).to_s
        raise ArgumentError, "workspace task #{key} is required" if value.empty?

        value
      end
    end
  end
end
