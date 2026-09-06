require "time"
require "hive/daily_digest"
require "hive/daily_digest/materiality"

module Hive
  module DailyDigest
    # Reconstructs which project registrations overlapped a persisted interval.
    # Missing or malformed history is represented as data, never silently
    # replaced with today's registry.
    class Coverage
      Result = Data.define(:projects, :gaps, :recovery_scopes)
      class PreCoverage < DailyDigest::MissingRecord; end

      def initialize(daily_config:, membership_history:, observed_at: -> { Time.now.utc })
        @config = stringify(daily_config)
        @observed_at = observed_at
        @history_errors = []
        @history_recovery_scopes = []
        begin
          coverage_started_at = utc(@config.fetch("coverage_started_at"))
          @events = Array(membership_history).filter_map.with_index do |raw, index|
            begin
              event = normalize_event(raw)
              @history_recovery_scopes << "registry:#{index}"
              @history_recovery_scopes << "registry:#{event.fetch('event_id')}"
              event if event.fetch("occurred_at") >= coverage_started_at
            rescue ArgumentError, KeyError, TypeError
              @history_errors << index
              nil
            end
          end.sort_by { |event| [ event.fetch("occurred_at"), event.fetch("event_id") ] }.freeze
        rescue KeyError, ArgumentError, TypeError => error
          @initialization_error = error
          @events = [].freeze
        end
      end

      def projects_for(starts_at:, ends_at:)
        raise @initialization_error if @initialization_error

        starts_at = utc(starts_at)
        ends_at = utc(ends_at)
        coverage_started_at = utc(@config.fetch("coverage_started_at"))
        if ends_at <= coverage_started_at
          raise PreCoverage, "digest interval predates durable coverage"
        end

        gaps = []
        @history_errors.each do |index|
          gaps << registry_gap(
            "registry_history_invalid", "project membership history contains an invalid entry",
            discriminator: index
          )
        end
        state = {}
        snapshot_valid = true
        Array(@config.fetch("initial_membership")).each do |project|
          normalized = normalize_project(project)
          state[membership_key(normalized)] = normalized
        rescue ArgumentError, KeyError, TypeError
          snapshot_valid = false
          gaps << registry_gap("registry_snapshot_invalid", "initial membership snapshot is invalid")
        end

        events = @events

        events.take_while { |event| event.fetch("occurred_at") <= starts_at }.each do |event|
          apply_event!(state, event, gaps)
        end
        overlapping = state.values.dup
        events.drop_while { |event| event.fetch("occurred_at") <= starts_at }
              .take_while { |event| event.fetch("occurred_at") < ends_at }
              .each do |event|
          apply_event!(state, event, gaps)
          overlapping << event.fetch("after") if event["after"]
        end

        projects = overlapping.compact.uniq { |project| membership_key(project) }
                              .sort_by { |project| [ project.fetch("name"), membership_key(project) ] }
        scopes = @history_recovery_scopes.dup
        scopes << "registry" if snapshot_valid
        Result.new(
          projects: projects.freeze,
          gaps: gaps.uniq { |gap| gap.fetch("gap_id") }.freeze,
          recovery_scopes: scopes.uniq.freeze
        )
      rescue KeyError, ArgumentError, TypeError => error
        raise DailyDigest::InvalidRecord, "daily digest coverage is not initialized: #{error.message}"
      end

      private

      def normalize_event(value)
        event = stringify(value)
        unless event["schema"] == "hive-project-membership" && event["schema_version"] == 1 &&
               %w[registered replaced unregistered pruned].include?(event["kind"])
          raise ArgumentError, "unsupported membership event"
        end
        event["occurred_at"] = utc(event.fetch("occurred_at"))
        event["event_id"] = event.fetch("event_id").to_s
        raise ArgumentError, "membership event id is missing" if event["event_id"].empty?
        event["before"] = normalize_project(event["before"]) if event["before"]
        event["after"] = normalize_project(event["after"]) if event["after"]
        case event.fetch("kind")
        when "registered"
          raise ArgumentError, "registration event is incomplete" unless event["after"] && !event["before"]
        when "replaced"
          raise ArgumentError, "replacement event is incomplete" unless event["after"] && event["before"]
        else
          raise ArgumentError, "removal event is incomplete" unless event["before"] && !event["after"]
        end
        event
      end

      def apply_event!(state, event, gaps)
        before = event["before"]
        after = event["after"]
        if before
          removed = state.delete(membership_key(before))
          unless removed
            # Replacement retains a registration id while changing path. Fall
            # back to the stable project identity before declaring a gap.
            key = state.keys.find { |candidate| state[candidate]["project_id"] == before["project_id"] }
            removed = state.delete(key) if key
          end
          unless removed
            gaps << registry_gap(
              "registry_history_discontinuous",
              "membership history removes a project that was not active",
              discriminator: event.fetch("event_id")
            )
          end
        end
        state[membership_key(after)] = after if after
      end

      def normalize_project(value)
        project = stringify(value)
        %w[name project_id registration_id path hive_state_path].each do |key|
          raise ArgumentError, "project #{key} is missing" if project[key].to_s.empty?
        end
        project.slice(
          "name", "project_id", "registration_id", "path", "real_path",
          "hive_state_path", "repository_identity", "registered_at"
        ).compact
      end

      def membership_key(project)
        [ project.fetch("project_id"), project.fetch("registration_id"), project.fetch("path") ].join("\0")
      end

      def registry_gap(code, reason, discriminator: nil)
        scope = discriminator ? "registry:#{discriminator}" : "registry"
        Materiality.build_gap(
          source: "project_registry", scope: scope, reason_code: code,
          reason: reason, observed_at: @observed_at.call
        )
      end

      def utc(value)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc
      end

      def stringify(value)
        case value
        when Hash then value.each_with_object({}) { |(key, child), out| out[key.to_s] = stringify(child) }
        when Array then value.map { |child| stringify(child) }
        else value
        end
      end
    end
  end
end
