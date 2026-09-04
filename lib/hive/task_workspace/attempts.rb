require "json"
require "hive/task_journal"
require "hive/task_workspace"

module Hive
  module TaskWorkspace
    class Attempts
      def initialize(projection:, attempt_store:, activities:, limits: Limits.new)
        @projection = projection.to_h
        @attempt_store = attempt_store
        @activities = Array(activities)
        @limits = limits
      end

      def call
        current_id = @projection.dig("identity", "attempt_id").to_s
        current_id = nil if current_id.empty?
        diagnostics = []
        truncated = false

        records = []
        fetched = {}
        bytes = 0
        seed_ids = ([ current_id ] + @activities.filter_map do |activity|
          attempt_id = activity["attempt_id"].to_s
          attempt_id unless attempt_id.empty? || attempt_id == Hive::TaskJournal::LEGACY_ATTEMPT_ID
        end).compact.uniq
        seed_ids.each do |attempt_id|
          record, consumed = fetch_attempt(attempt_id, diagnostics)
          next unless record
          if bytes + consumed > @limits.fetch(:attempt_bytes)
            diagnostics << diagnostic(
              "attempt_bytes_exhausted", @limits.fetch(:attempt_bytes), bytes + consumed
            )
            truncated = true
            break
          end
          fetched[attempt_id] = record
          records << record
          bytes += consumed
        end

        projected = records.map do |record|
          project_attempt(record, current_id: current_id)
        end.sort_by do |record|
          [ record.fetch("task_generation"), record.fetch("accepted_at").to_s,
            record.fetch("attempt_id") ]
        end
        if current_id && projected.none? { |record| record["attempt_id"] == current_id }
          diagnostics << diagnostic("current_attempt_missing", current_id, nil)
        end

        state = if truncated || diagnostics.any?
          projected.empty? ? "unavailable" : "partial"
        elsif projected.empty?
          "missing"
        else
          "current"
        end
        {
          "state" => state,
          "records" => projected,
          "groups" => groups(projected),
          "current_attempt_id" => current_id,
          "diagnostics" => diagnostics,
          "truncated" => truncated,
          "observed_bytes" => bytes
        }
      end

      private

      def fetch_attempt(attempt_id, diagnostics)
        record = @attempt_store.fetch(attempt_id)
        return [ nil, 0 ] unless record

        bytes = JSON.generate(record_hash(record)).bytesize
        [ record, bytes ]
      rescue StandardError => e
        diagnostics << {
          "source" => "attempt_record", "reason" => "attempt_fetch_failed",
          "attempt_id" => attempt_id, "detail" => e.class.name
        }
        [ nil, 0 ]
      end

      def project_attempt(record, current_id:)
        attempt_id = value(record, "attempt_id").to_s
        stage = value(record, "intended_stage").to_s
        generation = if record.respond_to?(:task_input_epoch)
          record.task_input_epoch
        else
          value(record, "task_input_epoch") || value(record, "task_generation")
        end
        routing = value(record, "routing") || {}
        requested_provider = routing.dig("route", "adapter") || value(record, "provider")
        {
          "attempt_id" => attempt_id,
          "project_slug" => value(record, "project"),
          "task_slug" => value(record, "task_slug"),
          "current" => !current_id.to_s.empty? && attempt_id == current_id.to_s,
          "stage" => stage,
          "task_generation" => generation,
          "ownership_generation" => value(record, "ownership_generation"),
          "state" => value(record, "state"),
          "outcome" => value(record, "outcome"),
          "accepted_at" => value(record, "accepted_at"),
          "started_at" => value(record, "started_at"),
          "ended_at" => value(record, "ended_at"),
          "requested_provider" => field(
            requested_provider, source: "attempt_record",
            state: requested_provider.nil? ? "unavailable" : "current",
            evidence_ref: "attempts/#{attempt_id}"
          ),
          "sessions" => sessions_for(attempt_id)
        }
      end

      def sessions_for(attempt_id)
        events = @activities.select do |record|
          record["event_type"] == "activity_recorded" &&
            record["attempt_id"].to_s == attempt_id.to_s &&
            %w[session_started session_finished].include?(record.dig("payload", "activity_kind"))
        end
        grouped = events.group_by { |record| record.dig("payload", "session_id").to_s }
        grouped.filter_map do |session_id, rows|
          next if session_id.empty?

          ordered = rows.sort_by do |record|
            [ record["occurred_at"].to_s,
              record.dig("payload", "activity_kind") == "session_finished" ? 1 : 0,
              record["event_id"].to_s ]
          end
          start = ordered.find { |record| record.dig("payload", "activity_kind") == "session_started" }
          finish = ordered.reverse.find { |record| record.dig("payload", "activity_kind") == "session_finished" }
          primary = finish || start
          payload = primary.fetch("payload")
          actual_model = finish&.dig("payload", "actual_model")
          {
            "session_id" => session_id,
            "role" => payload["role"],
            "provider" => payload["provider"],
            "requested_model" => field(
              (start || primary).dig("payload", "requested_model"),
              source: "runtime_receipt", state: value_state((start || primary).dig("payload", "requested_model")),
              evidence_ref: "sessions/#{session_id}"
            ),
            "actual_model" => field(
              actual_model, source: "runtime_receipt", state: value_state(actual_model),
              evidence_ref: "sessions/#{session_id}"
            ),
            "requested_effort" => (start || primary).dig("payload", "requested_effort"),
            "started_at" => (start || primary).dig("payload", "started_at") || start&.dig("occurred_at"),
            "ended_at" => finish&.dig("payload", "ended_at") || finish&.dig("occurred_at"),
            "health" => payload["health"],
            "outcome" => payload["outcome"],
            "live" => finish.nil? && payload["live"] == true,
            "timed_out" => payload["timed_out"] == true,
            "timeout_sec" => payload["timeout_sec"],
            "guards" => Array(payload["guards"]),
            "resource_observation" => finish&.dig("payload", "resource_observation"),
            "usage" => finish&.dig("payload", "usage")
          }
        end.sort_by { |session| [ session["started_at"].to_s, session["session_id"] ] }
      end

      def groups(records)
        records.group_by { |record| [ record["stage"], record["task_generation"] ] }
               .sort_by { |(stage, generation), _| [ generation.to_i, stage.to_s ] }
               .map do |(stage, generation), attempts|
          {
            "stage" => stage, "task_generation" => generation,
            "attempt_ids" => attempts.map { |attempt| attempt["attempt_id"] }
          }
        end
      end

      def field(value, source:, state:, evidence_ref:)
        Field.new(
          value: value, state: state, source: source,
          evidence_ref: evidence_ref, quality: "durable"
        ).to_h
      end

      def value_state(value)
        value.nil? || value.to_s.empty? ? "unavailable" : "current"
      end

      def record_hash(record)
        record.respond_to?(:to_h) ? record.to_h : record
      end

      def value(record, key)
        record.respond_to?(:[]) ? record[key] : nil
      end

      def diagnostic(reason, limit, observed)
        {
          "source" => "attempt_record", "reason" => reason,
          "limit" => limit, "observed" => observed
        }
      end
    end
  end
end
