require "digest"
require "hive/attempts/generation"
require "hive/markers"
require "hive/task"
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
      RetryTask = Struct.new(:id, :slug, :state_file, :folder, keyword_init: true)

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

      # Enqueue the explicit `hive plan ... --from 3-plan` rerun before a
      # 3-plan marker clear. Clearing alone leaves an empty markerless
      # plan.md that classifies straight back to :error, so re-entry must be
      # explicit. The request is bound to the immutable task id, the exact
      # ERROR marker generation, and the durable-attempt generation of the
      # post-clear artifact. A deterministic request id makes a daemon restart
      # between enqueue and clear idempotent. Returns the request id, or false
      # when durable enqueue fails so the caller can leave the marker intact.
      def requeue_plan_rerun(row, trigger:)
        task = plan_retry_task(row)
        task_id = task.id
        raise Hive::Error, "cannot queue a plan retry without a task id" if task_id.nil?

        marker = Hive::Markers.current(row.state_file)
        marker_id = marker.attrs["marker_id"].to_s
        if marker_id.empty?
          marker_id = "legacy-#{::Digest::SHA256.hexdigest(marker.raw.to_s)[0, 16]}"
        end

        markerless_body = Hive::Markers.without_markers(File.binread(row.state_file))
        progress_token = Hive::Attempts::Generation.artifact_token(
          task, state_file_content: markerless_body
        )
        task_generation = Hive::Attempts::Generation.resolve(
          task: task,
          project: row.project,
          intended_stage: row.stage,
          progress_token: progress_token
        ).task_generation
        request_id = ::Digest::SHA256.hexdigest(
          [ "hive-plan-error-retry-v1", row.project, task_id, row.stage, marker_id,
            task_generation ].join("\0")
        )[0, 32]

        request_id = begin
          @request_queue.write_request!(
            project: row.project,
            slug: row.slug,
            argv: [ "hive", "plan", row.slug, "--project", row.project, "--from", "3-plan" ], # coding-scoped: healer re-enters coding plan verb
            requestor: "healer",
            trigger: trigger,
            request_id: request_id,
            task_generation: task_generation,
            task_id: task_id,
            expected_stage: row.stage,
            expected_marker_name: row.marker,
            expected_marker_id: marker_id
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
        request_id
      end

      def plan_retry_task(row)
        Hive::Task.new(row.folder.to_s)
      rescue Hive::InvalidTaskPath
        # Extensions and focused unit tests may supply a structurally complete
        # status row without materialising the full project stage hierarchy.
        # Production status rows always take the strict Hive::Task path.
        RetryTask.new(
          id: row.respond_to?(:id) ? row.id : nil,
          slug: row.slug.to_s,
          state_file: row.state_file.to_s,
          folder: row.folder.to_s
        )
      end

      def log_plan_requeued(row, request_id)
        @logger.event(:heal_requeued,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      request_id: request_id)
      rescue StandardError
        nil
      end
    end
  end
end
