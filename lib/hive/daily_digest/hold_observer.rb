require "json"
require "hive/task"
require "hive/task_activity"
require "hive/task_journal"

module Hive
  module DailyDigest
    # Converts daemon-only provider, authority, and capacity dispositions into
    # idempotent task-journal transitions for historical boundary replay.
    class HoldObserver
      MAX_SEED_BYTES = 256 * 1024

      def initialize(activity_factory: nil)
        @activity_factory = activity_factory || ->(task) { Hive::TaskActivity.for_task(task) }
        @states = {}
      end

      def record(row, decision:, owner:, reason:, **details)
        folder = value(row, :folder).to_s
        return if folder.empty? || !File.directory?(folder)

        task = Hive::Task.new(folder)
        key = File.expand_path(folder)
        prior = @states.fetch(key) { @states[key] = seeded_state(folder) }
        current = hold_kind(row, decision: decision, owner: owner)
        return if prior == current || (prior.nil? && current.nil?)

        activity = @activity_factory.call(task)
        return unless activity

        state = current ? "active" : "cleared"
        kind = current || prior
        identity = {
          "kind" => kind, "state" => state, "stage" => value(row, :stage),
          "marker_id" => marker_attrs(row)["marker_id"], "reason" => reason.to_s
        }
        activity.record(
          kind: "hold_recorded",
          operation_id: "digest-hold:#{Hive::TaskActivity.fingerprint(identity)}",
          reason: reason.to_s.empty? ? "daemon operational hold changed" : reason,
          source: "attempt_dispatcher",
          payload: {
            "hold_kind" => kind, "state" => state,
            "provider" => provider(row, details), "retry_at" => details[:retry_at]
          }.compact
        )
        @states[key] = current
      rescue Hive::Error, SystemCallError, IOError, JSON::ParserError
        nil
      end

      private

      def hold_kind(row, decision:, owner:)
        return "provider" if marker_attrs(row)["reason"].to_s == "limits_reached" ||
                             decision.to_s == "provider_hold"
        return "capacity" if %w[attempt_capacity global_cap project_cap daily_cap].include?(decision.to_s)
        return "authority" if owner.to_s == "operator" &&
                              %w[task_history_invalid project_disabled legacy_layout quarantined
                                 project_dropped folder_missing folder_missing_nil].include?(decision.to_s)
      end

      def provider(row, details)
        marker_attrs(row)["provider"] || marker_attrs(row)["provider_account_id"] ||
          details.dig(:routing, "provider") || value(row, :provider)
      end

      def seeded_state(folder)
        path = File.join(folder, Hive::TaskJournal::JOURNAL_BASENAME)
        return unless File.file?(path) && !File.symlink?(path)

        size = File.size(path)
        offset = [ size - MAX_SEED_BYTES, 0 ].max
        lines = File.binread(path, MAX_SEED_BYTES, offset).lines
        lines.shift if offset.positive?
        state = nil
        lines.each do |line|
          row = JSON.parse(line)
          payload = row["payload"]
          next unless row["event_type"] == "activity_recorded" && payload.is_a?(Hash) &&
                      payload["activity_kind"] == "hold_recorded"

          state = payload["state"] == "active" ? payload["hold_kind"].to_s : nil
        rescue JSON::ParserError
          next
        end
        state.to_s.empty? ? nil : state
      end

      def marker_attrs(row)
        attrs = value(row, :marker_attrs)
        attrs.is_a?(Hash) ? attrs : {}
      end

      def value(row, key)
        row.respond_to?(key) ? row.public_send(key) : row[key]
      rescue KeyError, TypeError, NoMethodError
        nil
      end
    end
  end
end
