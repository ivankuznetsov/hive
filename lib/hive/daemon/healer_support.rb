require "hive/workflows"
require "hive/daemon/dispatch_request_queue"

module Hive
  module Daemon
    # Marker-attribute, baseline-seeding, and 3-plan requeue helpers for the
    # daemon's universal StaleAgentHealer.
    #
    # Relies on the host exposing `@controller`, `@logger`, and
    # `@request_queue` instance variables.
    module HealerSupport
      # Read the row's marker attrs hash, tolerating rows that predate the
      # `marker_attrs` accessor or carry a non-hash value.
      def marker_attrs_for(row)
        return row.marker_attrs if row.respond_to?(:marker_attrs) && row.marker_attrs.is_a?(Hash)

        {}
      end

      # The marker's own `reason=` attribute as a string — the single source
      # the universal healer keys retry telemetry and match attrs from.
      def marker_reason(row)
        marker_attrs_for(row)["reason"].to_s
      end

      # `clear_current` match attrs: pin the reason and, when present, the
      # marker_id so a stale status row cannot clear a newer marker that
      # gained an id between status and heal. Legacy no-id markers match on
      # `marker_id => nil` (evaluated under the markers lock by the caller).
      def marker_match_attrs(row, reason)
        marker_id = marker_attrs_for(row)["marker_id"].to_s
        { "reason" => reason, "marker_id" => marker_id.empty? ? nil : marker_id }
      end

      # Per-process retry budget key: project/slug/stage/reason. Deliberately
      # omits any failure signature so repeated failures for the same
      # task/stage/reason share one budget rather than minting a fresh one.
      def error_recovery_key(row, reason)
        [ row.project.to_s, row.slug.to_s, row.stage.to_s, reason.to_s ]
      end

      # Seed the pre-clear state-file mtime as the dispatch baseline so the
      # marker-clear rewrite looks like a settled edit-resume change on the
      # next status read rather than a first-sight row to strand via
      # `record_baseline`. Production always satisfies the responds-to check
      # (ConcurrencyController defines the method); a future controller swap
      # that dropped it would silently reintroduce first-sight stranding, so
      # emit a debug event instead of a silent no-op. Callers must guard a
      # nil `state_file_mtime` before reaching here.
      def observe_pre_clear_mtime(row)
        unless @controller.respond_to?(:observe_state_file_mtime)
          @logger.event(:marker_heal_observer_missing,
                        project: row.project,
                        slug: row.slug,
                        stage: row.stage,
                        state_file: row.state_file)
          return
        end

        @controller.observe_state_file_mtime(
          project: row.project,
          slug: row.slug,
          mtime: row.state_file_mtime
        )
      end

      # Enqueue the explicit `hive plan ... --from 3-plan` rerun after a
      # 3-plan marker clear. Clearing alone leaves an empty markerless
      # plan.md that classifies straight back to :error, so re-entry must be
      # explicit. `trigger:` distinguishes the calling healer. Carries its
      # own rescue and returns false when durable enqueue fails. The caller can
      # then restore a fresh guarded ERROR so the shared cooldown retries the
      # enqueue instead of stranding a markerless empty plan.
      def requeue_plan_rerun(row, trigger:)
        request_id = begin
          @request_queue.write_request!(
            project: row.project,
            slug: row.slug,
            argv: [ "hive", "plan", row.slug, "--project", row.project, "--from", "3-plan" ], # coding-scoped: healer re-enters coding plan verb
            requestor: "healer",
            trigger: trigger
          )
        rescue StandardError => e
          begin
            @logger.event(:heal_requeue_failed,
                          project: row.project,
                          slug: row.slug,
                          stage: row.stage,
                          error: "#{e.class}: #{e.message}",
                          remediation: "hive plan #{row.slug} --project #{row.project} --from 3-plan") # coding-scoped: healer re-enters coding plan verb
          rescue StandardError
            nil
          end
          return false
        end

        begin
          @logger.event(:heal_requeued,
                        project: row.project,
                        slug: row.slug,
                        stage: row.stage,
                        request_id: request_id)
        rescue StandardError
          nil
        end
        true
      end
    end
  end
end
