require "open3"
require "time"
require "yaml"
require "hive/agent_limit"
require "hive/lock"
require "hive/markers"
require "hive/process_kill"
require "hive/workflows"
require "hive/daemon/recovery_coordinator"
require "hive/attempts/lost_outcome"
require "hive/terminal_outcome"

module Hive
  module Daemon
    # Tick-time healer for in-flight markers whose backing agent isn't
    # actually alive, so the disk truth stops lying. The `agent_*` paths
    # rewrite the marker to ERROR / REVIEW_ERROR with a `reason` attribute
    # so the existing red-status surface in Hive::TaskAction kicks in; the
    # REVIEW_WORKING paths rewrite the marker to REVIEW_ERROR (and drop the
    # stale .lock). The next tick submits that durable failure to the same
    # RecoveryCoordinator used by every other retry surface.
    #
    # Two failure modes are healed, distinguished by the row's
    # `claude_pid_alive` field (populated by Hive::Commands::Status from
    # the per-task .lock file's `claude_pid` field — NOT from the
    # marker's `pid` attribute, which records the hive runner PID
    # instead):
    #
    #   - `agent_died`     — the .lock recorded a claude_pid that's
    #                        no longer alive (claude_pid_alive == false).
    #                        Covers SIGKILL, OOM, crash, hard reboot
    #                        of an attached agent.
    #   - `agent_orphaned` — no .lock claude_pid (claude_pid_alive ==
    #                        nil) and the marker's state-file mtime is
    #                        older than the grace window. Either the
    #                        daemon never dispatched the stage (the bug
    #                        that produced this healer), or the dispatch
    #                        process died before recording its PID in
    #                        the lock.
    #
    # REVIEW_WORKING markers are healed on two analogous paths:
    #   - `review_agent_died` — the review parent still holds a
    #                        verified-live .lock but its Claude child died
    #                        (live_task_lock == true, claude_pid_alive ==
    #                        false) AND the holder has no live child
    #                        processes (the actual "wedged" signal).
    #                        Terminate the wedged holder and record
    #                        REVIEW_ERROR (issue #320).
    #   - `review_orphaned`  — no verified-live lock holder
    #                        (live_task_lock != true) and the marker is
    #                        older than the grace window. A signal kill —
    #                        daemon restart SIGTERM/SIGKILL, OOM, hard
    #                        reboot — tore down the whole review tree
    #                        before it could write a terminal marker;
    #                        Stages::Review's in-process rescue never runs
    #                        on a kill. Record REVIEW_ERROR + drop any stale
    #                        lock so the sole recovery coordinator can retry.
    #
    # ERROR and REVIEW_ERROR are durable observations, not permanent workflow
    # terminals. Every reason uses the same shared cooldown, then this scheduler
    # submits the observation to RecoveryCoordinator. The coordinator alone
    # admits the durable request, clears by marker id, and re-enters the ordinary
    # stage. A failed rerun writes a fresh error marker and restarts the cooldown;
    # retries never exhaust.
    # This is intentionally reason-agnostic because files, configuration,
    # credentials, agent binaries, and provider state can change outside Hive.
    #
    # Skip cases:
    #   - controller.running_task? returns true (an in-process dispatch
    #     is live; do not race it)
    #   - row.live_task_lock is true (an externally-spawned `hive run` is
    #     holding the per-task .lock with a verified PID + start-time
    #     match; the runner is still inside the task even if its
    #     claude_pid is not yet recorded — do not race it). Issue #144.
    #   - project's legacy_stage_dirs is non-empty (we never touch markers
    #     in a half-migrated layout — the dispatcher already refuses to
    #     advance these)
    #   - placeholder marker still within grace (slow but normal dispatch)
    class StaleAgentHealer
      # These reasons retain a more specific audit label. Eligibility is still
      # governed exclusively by the shared cooldown.
      FIX_AUTO_COMMIT_RETRYABLE_REASONS = %w[
        fix_auto_commit_scope_failed
        fix_auto_commit_sign_policy_failed
        fix_auto_commit_signing_failed
      ].freeze

      def initialize(controller:, logger:, grace_sec: 300,
                     attempt_store: nil, attempt_dispatcher: nil,
                     lost_outcome_store: nil, lost_outcome_processor: nil,
                     auto_retry_enabled: true,
                     project_auto_retry_enabled: ->(_project) { true },
                     recovery_coordinator: nil)
        @controller = controller
        @logger = logger
        @grace_sec = grace_sec
        @attempt_store = attempt_store
        @attempt_dispatcher = attempt_dispatcher
        @lost_outcome_store = lost_outcome_store
        @lost_outcome_processor = lost_outcome_processor
        @auto_retry_enabled = auto_retry_enabled == true
        @project_auto_retry_enabled = project_auto_retry_enabled
        @recovery_coordinator = recovery_coordinator
      end

      # Lease-backed loss is processed independently of legacy marker rows.
      # The durable retry charge and predecessor link survive daemon restart,
      # while the outcome sidecar makes repeated ticks idempotent.
      def heal_attempt_losses(attempts, now: Time.now.utc)
        return unless @auto_retry_enabled
        return unless @attempt_store && @attempt_dispatcher &&
                      @lost_outcome_store && @lost_outcome_processor

        attempts = Array(attempts)
        return if attempts.empty?

        successors = @attempt_store.scan.records.each_with_object({}) do |candidate, index|
          predecessor_id = candidate["predecessor_attempt_id"]
          index[predecessor_id] ||= candidate if predecessor_id
        end

        attempts.each do |attempt|
          next unless @project_auto_retry_enabled.call(attempt["project"])

          outcome = @lost_outcome_processor.process(attempt, now: now)
          next unless outcome["status"] == "ready"

          existing = successors[attempt.attempt_id]
          if existing
            @lost_outcome_store.update(
              attempt, now: now, status: "successor_dispatched",
              successor_attempt_id: existing.attempt_id,
              diagnostic: nil
            )
            next
          end

          task = task_for_attempt(attempt, outcome)
          unless task
            diagnostic = "task could not be located for successor yet; retrying"
            next if outcome["diagnostic"] == diagnostic

            @lost_outcome_store.update(
              attempt, now: now, status: "ready",
              diagnostic: diagnostic
            )
            next
          end

          next unless attempt_loss_retry_due?(attempt, outcome, now: now)

          outcome = @lost_outcome_store.update(
            attempt,
            now: now,
            status: "ready",
            last_retry_at: now.utc.iso8601(6),
            diagnostic: nil
          )
          result = @attempt_dispatcher.dispatch_successor(
            predecessor: attempt,
            task: task,
            project: attempt["project"],
            argv: successor_argv(attempt, task),
            request_id: "attempt-loss-#{outcome.fetch('idempotency_key')[0, 24]}",
            provider: attempt["provider"],
            inherited_outputs: (attempt["inherited_outputs"] + attempt["current_outputs"]).uniq,
            retry_charge: attempt["retry_charge"] + 1,
            interactive: false,
            now: now
          )
          if result.status == :deferred
            @lost_outcome_store.update(
              attempt,
              now: now,
              status: "ready",
              diagnostic: "successor dispatch deferred#{": #{result.reason}" if result.reason}; retrying after cooldown"
            )
            next
          end

          @lost_outcome_store.update(
            attempt, now: now, status: "successor_dispatched",
            successor_attempt_id: result.attempt&.attempt_id,
            diagnostic: nil
          )
          successors[attempt.attempt_id] = result.attempt if result.attempt
          @logger.event(
            :marker_healed,
            project: attempt["project"], slug: attempt["task_slug"],
            stage: attempt["intended_stage"], reason: "attempt_lost",
            attempt_id: attempt.attempt_id,
            successor_attempt_id: result.attempt&.attempt_id,
            attempts: attempt["retry_charge"] + 1
          )
        rescue StandardError => e
          @logger.event(
            :marker_heal_failed,
            project: attempt["project"], slug: attempt["task_slug"],
            stage: attempt["intended_stage"], reason: "attempt_lost",
            error: "#{e.class}: #{e.message}"
          )
        end
      end

      # Walk the row set, heal stale agent_working markers in place.
      # `legacy_layout_projects` is a Set/Hash of project names whose
      # status payload reported half-migrated stage dirs — we refuse to
      # touch markers in those projects. `now:` matches the convention
      # used by every other daemon component (Dispatcher#tick,
      # PrMergeWatcher#tick, ChildSupervisor#reap_all) so a single tick
      # observes one frozen `now` across every subsystem.
      #
      # Filter keys off the on-disk marker name (`row.marker`), not the
      # in-memory `row.action`. TaskAction now reclassifies stale
      # agent_working rows as `:error` immediately (the U4 belt-and-
      # suspenders) which would otherwise hide them from this heal pass
      # via `row.action == "error"`. The on-disk marker is unchanged
      # until *we* rewrite it, so it's the authoritative signal here.
      def heal(rows, now: Time.now, legacy_layout_projects: {}, auto_retry_projects: nil)
        rows.each do |row|
          next if legacy_layout_projects.include?(row.project)
          next if @controller.running_task?(project: row.project, slug: row.slug)

          if %w[error review_error].include?(row.marker.to_s)
            heal_recoverable_error_if_auto_recoverable(row, now: now) if auto_retry_allowed?(
              row, auto_retry_projects
            )
            next
          end

          if row.marker.to_s == "review_working"
            heal_review_row_if_stale(row, now: now)
            next
          end

          next unless row.marker.to_s == "agent_working"
          # Externally-spawned `hive run` is holding the per-task .lock;
          # claude_pid_alive may still be nil because the runner has not
          # written its claude_pid yet (auto-rebase, etc.). Healing here
          # would race the live runner. Issue #144.
          next if row.live_task_lock == true

          reason = classify_stale(row, now: now)
          next unless reason

          heal_row(row, reason: reason)
        end
      end

      # Read-only assessment shared with the scheduler disposition publisher.
      # Keeping the deadline and the safety decision here prevents status from
      # claiming scheduler ownership for a row the healer will deliberately
      # leave parked.
      def retry_assessment(row, now: Time.now.utc)
        return unavailable_recovery_assessment unless @recovery_coordinator

        @recovery_coordinator.assessment(row, now: now)
      end

      def auto_retry_enabled?
        @auto_retry_enabled
      end

      def unavailable_recovery_assessment
        {
          due: false,
          retry_at: nil,
          safe: false,
          safety_reason: "recovery_coordinator_unavailable"
        }
      end

      private

      def attempt_loss_retry_due?(attempt, outcome, now:)
        limited_at = parse_retry_time(outcome["last_retry_at"]) ||
                     parse_retry_time(attempt["loss"].to_h["at"])
        Hive::AgentLimit.retry_due?(limited_at: limited_at, now: now)
      end

      def parse_retry_time(value)
        Time.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def auto_retry_allowed?(row, projects)
        @auto_retry_enabled &&
          !Hive::TerminalOutcome.semantic_error?(marker_attrs_for(row)) &&
          (projects.nil? || projects.include?(row.project))
      end

      def task_for_attempt(attempt, outcome)
        folder = outcome["task_folder"]
        return Hive::Task.new(folder) if folder && File.directory?(folder)

        target = attempt["task_id"].to_s.empty? ? attempt["task_slug"] : attempt["task_id"]
        Hive::TaskResolver.new(target, project_filter: attempt["project"]).resolve
      rescue Hive::Error, SystemCallError
        nil
      end

      def successor_argv(attempt, task)
        argv = Array(attempt["worker_argv"]).dup
        return argv unless argv.first == "hive" && argv.length >= 3

        # The durable command is replayed byte-for-byte except for its task
        # locator, which must follow an atomic stage move performed before the
        # owner was lost. Once a workflow action has reached its admitted
        # target, its source assertion is no longer valid and is removed; all
        # other recovery/JSON flags remain intact.
        argv[2] = task.folder
        if "#{task.stage_index}-#{task.stage_name}" == attempt["intended_stage"]
          while (index = argv.index("--from"))
            argv.slice!(index, 2)
          end
          argv.reject! { |value| value.start_with?("--from=") }
        end
        argv
      end

      def heal_recoverable_error_if_auto_recoverable(row, now:)
        return if row.live_task_lock == true
        return unless @recovery_coordinator
        return unless auto_recoverable?(row, now: now)

        coordinate_recovery(row, now: now)
      rescue StandardError => e
        @logger.event(:marker_heal_failed,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      reason: recovery_heal_label(row),
                      error: "#{e.class}: #{e.message}")
      end

      def auto_recoverable?(row, now:)
        assessment = retry_assessment(row, now: now)
        assessment[:due] && assessment[:safe]
      end

      def recovery_heal_label(row)
        reason = marker_reason(row)
        return review_heal_label(reason) if row.marker.to_s == "review_error"

        error_heal_label(row, reason)
      end

      def error_heal_label(row, reason)
        return "finalize_unpushed_commits" if Hive::Workflows.coding_row?(row) && row.stage.to_s == "8-finalize" && reason == "unpushed_commits" # coding-scoped: finalize unpushed branch recovery
        return "limits_reached" if reason == "limits_reached"
        return "stage_timeout" if reason == "timeout"
        return "clean_exit_residue" if reason == "ensure_clean_on_exit_failed"
        return "agent_loss_retry" if %w[tmux_session_terminated agent_orphaned].include?(reason)

        "error_retry"
      end

      # Map a review marker reason to the healer's `reason:` log label.
      # `review_agent_died` keeps its own label; every other
      # auto-recoverable review reason (today only the tmux-death subset
      # of `reviewer_partial_failure`) logs as
      # `reviewer_tmux_session_terminated`. The marker's literal reason is
      # carried separately as `marker_reason:`.
      def review_heal_label(reason)
        case reason
        when "review_agent_died" then "review_agent_died"
        when "limits_reached" then "reviewer_limits_reached"
        when "all_failed" then "reviewer_all_failed"
        when "fix_failed" then "fix_claude_stop_hook"
        when *FIX_AUTO_COMMIT_RETRYABLE_REASONS then "fix_auto_commit_retry"
        when "reviewer_partial_failure" then "reviewer_tmux_session_terminated"
        else "review_error_retry"
        end
      end

      def coordinate_recovery(row, now:)
        receipt = @recovery_coordinator.request(
          row: row, requestor: "healer", now: now
        )
        log_coordinated_recovery(row, receipt)
        receipt
      end

      def log_coordinated_recovery(row, receipt)
        event = receipt.status == "queued" ? :recovery_requested : :recovery_blocked
        @logger.event(
          event,
          project: row.project,
          slug: row.slug,
          stage: row.stage,
          request_id: receipt.request_id,
          attempt_id: receipt.attempt_id,
          lifecycle: receipt.status,
          phase: receipt.phase,
          failure_origin: receipt.failure_origin,
          next_eligible_at: receipt.next_eligible_at,
          owner: receipt.owner,
          reason: receipt.reason,
          remediation: receipt.remediation
        )
      rescue StandardError
        nil
      end

      def heal_review_row_if_stale(row, now:)
        if row.live_task_lock == true
          heal_wedged_review_row(row)
        else
          heal_orphaned_review_row(row, now: now)
        end
      end

      # Case A (issue #320): the review parent still holds a verified-live
      # .lock but its Claude child died — terminate the wedged holder,
      # claim the lock, and record a terminal failure for the coordinator.
      def heal_wedged_review_row(row)
        return unless row.claude_pid_alive == false

        holder = task_lock_holder(row)
        return unless task_lock_matches_status_snapshot?(holder, row)
        return unless wedged_review_lock_holder?(holder)

        marker_attrs = review_marker_attrs(row)
        return unless review_marker_matches?(row, marker_attrs)

        # Terminate only the exact holder identity captured by status, then
        # acquire our own lock generation before transitioning. A replacement run,
        # undeletable lock, or still-live post-KILL holder makes the claim fail
        # closed and leaves the marker untouched.
        terminate_lock_holder(holder)
        transitioned = with_review_heal_lock(row, reason: "review_agent_died") do
          transition_review_working_to_error(
            row, expected_attrs: marker_attrs, reason: "review_agent_died"
          )
        end
        return unless transitioned

        @logger.event(:marker_healed,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      prior_marker: row.marker,
                      reason: "review_agent_died",
                      state_file: row.state_file,
                      phase: marker_attrs["phase"],
                      pass: marker_attrs["pass"],
                      lock_pid: holder["pid"],
                      claude_pid: holder["claude_pid"])
      rescue StandardError => e
        @logger.event(:marker_heal_failed,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      reason: "review_agent_died",
                      error: "#{e.class}: #{e.message}")
      end

      # Case B: no verified-live lock holder. A signal kill — daemon
      # restart SIGTERM/SIGKILL, OOM, or a hard reboot — tore down the
      # whole review process tree before it could write a terminal
      # marker, orphaning REVIEW_WORKING. The in-process rescue in
      # Stages::Review only runs for Ruby-level exceptions, never for a
      # kill, and the wedged-holder path above requires a live holder, so
      # nothing else reconciles this. Past the grace window — so we don't
      # race a runner that just set REVIEW_WORKING but hasn't recorded its
      # lock yet (controller.running_task? already excludes in-process
      # dispatches) — claim the task lock, transition the marker, and release our
      # claim so the coordinator can recover review under normal concurrency
      # control. Claiming closes the stale-status race where an external run
      # acquires a fresh .lock between the status snapshot and this heal.
      def heal_orphaned_review_row(row, now:)
        mtime = row.state_file_mtime
        return unless mtime && (now - mtime) > @grace_sec

        marker_attrs = review_marker_attrs(row)
        transitioned = with_review_heal_lock(row, reason: "review_orphaned") do
          transition_review_working_to_error(
            row, expected_attrs: marker_attrs, reason: "review_orphaned"
          )
        end
        return unless transitioned

        @logger.event(:marker_healed,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      prior_marker: row.marker,
                      reason: "review_orphaned",
                      state_file: row.state_file,
                      phase: marker_attrs["phase"],
                      pass: marker_attrs["pass"])
      rescue StandardError => e
        @logger.event(:marker_heal_failed,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      reason: "review_orphaned",
                      error: "#{e.class}: #{e.message}")
      end

      def task_lock_holder(row)
        lock_path = File.join(row.folder.to_s, ".lock")
        data = YAML.safe_load(File.read(lock_path), permitted_classes: [ Time ]) || {}
        data.is_a?(Hash) ? data : nil
      rescue StandardError
        nil
      end

      def task_lock_matches_status_snapshot?(holder, row)
        return false unless holder.is_a?(Hash)
        return false unless row.task_lock_pid.is_a?(Integer)
        return false unless holder["pid"] == row.task_lock_pid
        return false unless holder["process_start_time"].to_s == row.task_lock_process_start_time.to_s

        holder["lock_id"].to_s == row.task_lock_id.to_s
      end

      def review_marker_matches?(row, expected_attrs)
        marker = Hive::Markers.current(row.state_file)
        return false unless marker.name == :review_working

        expected_attrs.all? { |key, value| marker.attrs[key.to_s].to_s == value.to_s }
      end

      def wedged_review_lock_holder?(holder)
        return false unless holder.is_a?(Hash)

        pid = holder["pid"]
        return false unless pid.is_a?(Integer) && pid_alive?(pid)

        recorded = holder["process_start_time"]
        live = Hive::Lock.process_start_time(pid)
        return false if recorded && live != recorded

        children = child_pids(pid)
        children && children.empty?
      end

      def review_marker_attrs(row)
        attrs = marker_attrs_for(row)
        marker_id = attrs["marker_id"].to_s
        out = { "marker_id" => marker_id.empty? ? nil : marker_id }
        out["phase"] = attrs["phase"] if attrs["phase"]
        out["pass"] = attrs["pass"] if attrs["pass"]
        out
      end

      def transition_review_working_to_error(row, expected_attrs:, reason:)
        return false unless review_marker_matches?(row, expected_attrs)

        attrs = expected_attrs.compact.merge("reason" => reason)
        Hive::Markers.set(row.state_file, :review_error, attrs)
        true
      end

      def marker_attrs_for(row)
        return row.marker_attrs if
          row.respond_to?(:marker_attrs) && row.marker_attrs.is_a?(Hash)

        {}
      end

      def marker_reason(row)
        marker_attrs_for(row)["reason"].to_s
      end

      def pid_alive?(pid)
        Hive::ProcessKill.pid_alive?(pid)
      end

      def child_pids(pid)
        out, _err, status = Open3.capture3("pgrep", "-P", pid.to_i.to_s)
        return [] if status.exitstatus == 1
        return nil unless status.success?

        out.lines.filter_map { |line| Integer(line.strip, exception: false) }
      rescue Errno::ENOENT
        nil
      end

      def terminate_lock_holder(holder)
        pid = holder["pid"]
        return unless pid.is_a?(Integer)
        return unless lock_holder_process_alive?(holder)

        Process.kill("TERM", pid)
        deadline = Time.now + 1
        while Time.now < deadline
          return unless lock_holder_process_alive?(holder)

          sleep 0.05
        end
        Process.kill("KILL", pid) if lock_holder_process_alive?(holder)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def lock_holder_process_alive?(holder)
        pid = holder["pid"]
        return false unless pid.is_a?(Integer) && pid_alive?(pid)

        recorded = holder["process_start_time"]
        recorded.nil? || Hive::Lock.process_start_time(pid) == recorded
      end

      def with_review_heal_lock(row, reason:)
        Hive::Lock.with_task_lock(
          row.folder.to_s,
          "owner" => "stale_agent_healer",
          "reason" => reason
        ) { yield }
      rescue Hive::ConcurrentRunError
        # A runner acquired the task after this tick's status snapshot.
        # Leave both its lock and the marker untouched; the next tick will
        # reconcile the new generation.
        false
      end

      def classify_stale(row, now:)
        case row.claude_pid_alive
        when false
          :agent_died
        when nil
          mtime = row.state_file_mtime
          return nil unless mtime

          (now - mtime) > @grace_sec ? :agent_orphaned : nil
        else
          # true → live agent; nothing to heal
          nil
        end
      end

      def heal_row(row, reason:)
        Hive::Markers.set(row.state_file, :error, reason: reason.to_s)
        @logger.event(:marker_healed,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      prior_marker: row.marker,
                      reason: reason.to_s,
                      state_file: row.state_file)
      rescue StandardError => e
        # Never crash a tick on a single bad row. Disk errors (ENOSPC,
        # EACCES) surface here and we log + skip; the next tick will
        # retry. Markers.set is atomic via tempfile + rename so a torn
        # write can't leave the marker partially rewritten.
        @logger.event(:marker_heal_failed,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      reason: reason.to_s,
                      error: "#{e.class}: #{e.message}")
      end
    end
  end
end
