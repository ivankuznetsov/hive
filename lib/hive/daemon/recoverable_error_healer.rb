require "time"

require "hive/daemon/auto_retry_safety"
require "hive/daemon/health_probe"
require "hive/daemon/health_signal"
require "hive/daemon/recoverable_error_classifier"
require "hive/daemon/dispatch_request_queue"
require "hive/events"
require "hive/markers"
require "hive/workflows"

module Hive
  module Daemon
    # Tick-time healer for a narrow allowlist of terminal ERROR markers whose
    # cause is an external dependency outage rather than task-domain failure.
    class RecoverableErrorHealer
      MAX_AUTO_RETRIES = 2
      BACKOFF_SECOND_SEC = 1800

      def initialize(controller:, logger:, config:, health_probe: nil,
                     classifier: Hive::Daemon::RecoverableErrorClassifier,
                     safety: Hive::Daemon::AutoRetrySafety,
                     health_signal: Hive::Daemon::HealthSignal,
                     request_queue: Hive::Daemon::DispatchRequestQueue)
        @controller = controller
        @logger = logger
        @config = config || {}
        @health_probe = health_probe || Hive::Daemon::HealthProbe.new(
          config: @config,
          project_root: nil
        )
        @classifier = classifier
        @safety = safety
        @health_signal = health_signal
        @request_queue = request_queue
        @attempts = Hash.new(0)
        @last_fingerprint = {}
        @last_attempt_at = {}
        @last_clear_at = {}
        @exhausted_logged = {}
        @negative_audits = {}
      end

      def heal(rows, now: Time.now, legacy_layout_projects: {})
        return unless enabled?

        @health_probe.start_tick(now.to_f) if @health_probe.respond_to?(:start_tick)
        rows.each { |row| heal_row(row, now: now, legacy_layout_projects: legacy_layout_projects) }
      end

      private

      def heal_row(row, now:, legacy_layout_projects:)
        return if legacy_layout_projects.include?(row.project)
        return if row.marker.to_s != "error"
        return if row.live_task_lock == true
        return if @controller.running_task?(project: row.project, slug: row.slug)

        reason = marker_reason(row)
        category = @classifier.classify(
          reason: reason,
          attrs: marker_attrs(row),
          stage: row.stage,
          workflow: row.workflow
        )
        unless category
          audit_skip(row, now: now, reason: reason, category: nil, action: "unknown_reason",
                    rationale: "marker reason or diagnostic is not on the recoverable allowlist")
          return
        end

        safe, safety_reason = @safety.safe_to_retry?(row)
        unless safe
          audit_skip(row, now: now, reason: reason, category: category, action: "unsafe_work_area",
                    rationale: safety_reason)
          return
        end

        key = recovery_key(row, reason)
        attempts = @attempts[key]
        if attempts >= MAX_AUTO_RETRIES
          log_exhausted_once(row, key, reason: reason, category: category, attempts: attempts)
          return
        end

        fingerprint = @health_signal.fingerprint(
          reason: category,
          config: @config,
          project_root: nil,
          env: ENV,
          now: now
        )
        unless @health_signal.changed_or_fallback?(
          current_fingerprint: fingerprint,
          last_fingerprint: @last_fingerprint[key],
          last_attempt_at: @last_attempt_at[key],
          now: now
        )
          audit_skip(row, now: now, reason: reason, category: category, action: "unchanged_signal",
                    rationale: "health signal unchanged within fallback window", fingerprint: fingerprint,
                    attempts: attempts)
          return
        end

        if attempts.positive? && @last_clear_at[key] && now - @last_clear_at[key] < BACKOFF_SECOND_SEC
          audit_skip(row, now: now, reason: reason, category: category, action: "backoff",
                    rationale: "waiting for second retry backoff", fingerprint: fingerprint,
                    attempts: attempts)
          return
        end

        probe = @health_probe.probe(category)
        unless probe[:ok]
          @last_fingerprint[key] = fingerprint
          @last_attempt_at[key] = now
          audit_skip(row, now: now, reason: reason, category: category, action: "probe_failed",
                    rationale: "health probe failed", fingerprint: fingerprint,
                    attempts: attempts, probes: probe[:probes])
          return
        end

        return unless Hive::Markers.clear_current(
          row.state_file,
          expected_name: :error,
          match_attrs: marker_match_attrs(row, reason)
        )

        observe_pre_clear_mtime(row)
        attempts += 1
        @attempts[key] = attempts
        @last_fingerprint[key] = fingerprint
        @last_attempt_at[key] = now
        @last_clear_at[key] = now
        audit_retry(row, now: now, reason: reason, category: category, fingerprint: fingerprint,
                    attempts: attempts, probes: probe[:probes])
        requeue_plan_rerun(row) if Hive::Workflows.coding_row?(row) && row.stage.to_s == "3-plan"
      rescue StandardError => e
        @logger.event(:auto_retry_failed,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      reason: marker_reason(row),
                      error: "#{e.class}: #{e.message}")
      end

      def enabled?
        @config.dig("daemon", "auto_retry", "enabled") != false
      end

      def audit_retry(row, now:, reason:, category:, fingerprint:, attempts:, probes:)
        message = "auto-retry: #{category} healthy, cleared #{reason} (attempt #{attempts}/#{MAX_AUTO_RETRIES})"
        emit_task_event(row, :auto_retry, message)
        @logger.event(:auto_retry,
                      **audit_attrs(row, reason: reason, category: category,
                                    fingerprint: fingerprint, attempts: attempts,
                                    action: "cleared", rationale: message,
                                    probes: probes, now: now))
      end

      def audit_skip(row, now:, reason:, category:, action:, rationale:, fingerprint: nil,
                     attempts: nil, probes: nil)
        key = [
          row.project.to_s, row.slug.to_s, row.stage.to_s, reason.to_s,
          action.to_s, fingerprint.to_s, rationale.to_s
        ]
        return if @negative_audits[key]

        @negative_audits[key] = true
        message = "not retried: #{rationale}"
        emit_task_event(row, :auto_retry_skipped, message)
        @logger.event(:auto_retry_skipped,
                      **audit_attrs(row, reason: reason, category: category,
                                    fingerprint: fingerprint, attempts: attempts,
                                    action: action, rationale: rationale,
                                    probes: probes, now: now))
      end

      def log_exhausted_once(row, key, reason:, category:, attempts:)
        return if @exhausted_logged[key]

        @exhausted_logged[key] = true
        message = "not retried: auto-retry exhausted for #{reason} (#{attempts}/#{MAX_AUTO_RETRIES})"
        emit_task_event(row, :auto_retry_skipped, message)
        @logger.event(:auto_retry_exhausted,
                      **audit_attrs(row, reason: reason, category: category,
                                    attempts: attempts, max_attempts: MAX_AUTO_RETRIES,
                                    action: "exhausted", rationale: message,
                                    now: Time.now))
      end

      def audit_attrs(row, reason:, category:, action:, rationale:, now:, fingerprint: nil,
                      attempts: nil, max_attempts: MAX_AUTO_RETRIES, probes: nil)
        attrs = marker_attrs(row)
        {
          project: row.project,
          slug: row.slug,
          task_id: task_id(row),
          stage: row.stage,
          marker_id: attrs["marker_id"],
          reason: reason,
          category: category,
          probes: probes,
          fingerprint: fingerprint,
          attempts: attempts,
          max_attempts: max_attempts,
          action: action,
          rationale: rationale,
          at: now.utc.iso8601
        }.compact
      end

      def emit_task_event(row, type, message)
        return if row.folder.to_s.empty?

        Hive::Events.emit(
          task_folder: row.folder,
          slug: row.slug,
          stage: row.stage,
          event_type: type,
          message: message
        )
      end

      def task_id(row)
        return nil unless row.folder && File.exist?(File.join(row.folder, "meta.yml"))

        require "hive/task_meta"
        Hive::TaskMeta.read(row.folder)[:id]
      rescue StandardError
        nil
      end

      def observe_pre_clear_mtime(row)
        return unless row.state_file_mtime
        return unless @controller.respond_to?(:observe_state_file_mtime)

        @controller.observe_state_file_mtime(
          project: row.project,
          slug: row.slug,
          mtime: row.state_file_mtime
        )
      end

      def requeue_plan_rerun(row)
        request_id = @request_queue.write_request!(
          project: row.project,
          slug: row.slug,
          argv: [ "hive", "plan", row.slug, "--project", row.project, "--from", "3-plan" ],
          requestor: "healer",
          trigger: "recoverable_error_auto_retry"
        )
        @logger.event(:heal_requeued,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      request_id: request_id)
      rescue StandardError => e
        @logger.event(:heal_requeue_failed,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      error: "#{e.class}: #{e.message}",
                      remediation: "hive plan #{row.slug} --project #{row.project} --from 3-plan")
      end

      def marker_match_attrs(row, reason)
        attrs = marker_attrs(row)
        marker_id = attrs["marker_id"].to_s
        match = { "reason" => reason }
        match["marker_id"] = marker_id.empty? ? nil : marker_id
        match
      end

      def marker_reason(row)
        marker_attrs(row)["reason"].to_s
      end

      def marker_attrs(row)
        row.respond_to?(:marker_attrs) && row.marker_attrs.is_a?(Hash) ? row.marker_attrs : {}
      end

      def recovery_key(row, reason)
        [ row.project.to_s, row.slug.to_s, row.stage.to_s, reason.to_s ]
      end
    end
  end
end
