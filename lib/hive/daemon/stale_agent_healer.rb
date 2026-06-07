require "digest"
require "open3"
require "yaml"
require "hive/lock"
require "hive/markers"

module Hive
  module Daemon
    # Tick-time healer for in-flight markers whose backing agent isn't
    # actually alive, so the disk truth stops lying. The `agent_*` paths
    # rewrite the marker to ERROR / REVIEW_ERROR with a `reason` attribute
    # so the existing red-status surface in Hive::TaskAction kicks in; the
    # REVIEW_WORKING paths instead CLEAR the marker (and drop the stale
    # .lock) so the daemon simply re-dispatches review.
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
    #                        Terminate the wedged holder and clear the
    #                        marker (issue #320).
    #   - `review_orphaned`  — no verified-live lock holder
    #                        (live_task_lock != true) and the marker is
    #                        older than the grace window. A signal kill —
    #                        daemon restart SIGTERM/SIGKILL, OOM, hard
    #                        reboot — tore down the whole review tree
    #                        before it could write a terminal marker;
    #                        Stages::Review's in-process rescue never runs
    #                        on a kill. Clear the marker + drop any stale
    #                        lock so review re-dispatches.
    #
    # Some terminal ERROR markers are also auto-retryable. `8-finalize`
    # `reason=unpushed_commits` can fail during ordinary interruptions
    # (sleep/network) even though the task state remains recoverable by
    # rerunning finalize. Later-stage `reason=tmux_session_terminated`
    # and `reason=agent_orphaned` markers in 7-artifacts / 8-finalize
    # also describe a lost agent session, not a task-domain failure.
    # Clearing those specific markers lets the normal daemon dispatch
    # rerun the stage up to the configured limit (default 3) before
    # leaving the marker red for manual recovery. There is no healer-side
    # backoff between those retries — the only thing spacing them is the
    # stage's own re-dispatch runtime, not any delay enforced here.
    #
    # Unlike the review path (`review_error_signature`), the terminal
    # ERROR recovery key (`error_auto_recovery_key`) deliberately omits a
    # failure signature: repeated failures for the same task/stage/reason
    # share one retry budget by design, so a fresh marker id does not
    # silently earn a fresh budget. This asymmetry is intentional, not an
    # oversight.
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
      REVIEW_ERROR_AUTO_RECOVERY_LIMIT = 3
      ERROR_AUTO_RECOVERY_LIMIT = 3

      def initialize(controller:, logger:, grace_sec: 300,
                     review_error_auto_recovery_limit: REVIEW_ERROR_AUTO_RECOVERY_LIMIT,
                     error_auto_recovery_limit: ERROR_AUTO_RECOVERY_LIMIT)
        @controller = controller
        @logger = logger
        @grace_sec = grace_sec
        @review_error_auto_recovery_limit = review_error_auto_recovery_limit
        @error_auto_recovery_limit = error_auto_recovery_limit
        @review_error_auto_recoveries = Hash.new(0)
        @error_auto_recoveries = Hash.new(0)
        @review_error_recovery_exhausted = {}
        @error_recovery_exhausted = {}
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
      def heal(rows, now: Time.now, legacy_layout_projects: {})
        rows.each do |row|
          next if legacy_layout_projects.include?(row.project)
          next if @controller.running_task?(project: row.project, slug: row.slug)

          if row.marker.to_s == "review_error"
            heal_review_error_if_auto_recoverable(row)
            next
          end

          if row.marker.to_s == "error"
            heal_error_if_auto_recoverable(row)
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

      private

      def heal_error_if_auto_recoverable(row)
        return if row.live_task_lock == true
        return unless auto_recoverable_error?(row)
        # The clear makes a markerless terminal-error row take the
        # edit-resume path; without a pre-clear mtime to seed as the
        # dispatch baseline, that row can strand as first-sight
        # `record_baseline`.
        return if row.state_file_mtime.nil?

        marker_reason = marker_reason(row)
        heal_label = error_heal_label(row, marker_reason)
        recovery_key = error_auto_recovery_key(row, reason: marker_reason)
        attempts = @error_auto_recoveries[recovery_key]
        if attempts >= @error_auto_recovery_limit
          log_recovery_exhausted_once(
            @error_recovery_exhausted,
            recovery_key,
            row,
            reason: heal_label,
            marker_reason: marker_reason,
            attempts: attempts,
            max_attempts: @error_auto_recovery_limit,
            remediation: error_recovery_remediation(row, marker_reason)
          )
          return
        end

        # A false return is an intentional, silent no-op: either a benign
        # race (finalize already advanced and rewrote/removed the marker)
        # or a marker_id mismatch (the on-disk marker is newer than this
        # stale status row). Either way we must NOT consume a retry or log
        # — the budget increment below is deliberately ordered AFTER this
        # guard so only a real clear counts against the limit. The next
        # tick re-reads the marker and reconciles.
        return unless Hive::Markers.clear_current(
          row.state_file,
          expected_name: :error,
          match_attrs: auto_recoverable_error_match_attrs(row, reason: marker_reason)
        )

        observe_pre_clear_mtime(row)
        attempts += 1
        @error_auto_recoveries[recovery_key] = attempts
        @logger.event(:marker_healed,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      prior_marker: row.marker,
                      reason: heal_label,
                      marker_reason: marker_reason,
                      state_file: row.state_file,
                      attempts: attempts,
                      max_attempts: @error_auto_recovery_limit)
      rescue StandardError => e
        @logger.event(:marker_heal_failed,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      reason: error_heal_label(row, marker_reason(row)),
                      error: "#{e.class}: #{e.message}")
      end

      def auto_recoverable_error?(row)
        reason = marker_reason(row)
        return true if row.stage.to_s == "8-finalize" && reason == "unpushed_commits"

        %w[7-artifacts 8-finalize].include?(row.stage.to_s) &&
          %w[tmux_session_terminated agent_orphaned].include?(reason)
      end

      def error_heal_label(row, reason)
        return "finalize_unpushed_commits" if row.stage.to_s == "8-finalize" && reason == "unpushed_commits"

        "terminal_agent_loss"
      end

      def error_recovery_remediation(row, reason)
        if row.stage.to_s == "8-finalize" && reason == "unpushed_commits"
          return "rerun finalize (`hive run #{row.project} #{row.slug}`) " \
                 "or push the branch manually"
        end

        "rerun #{row.stage} (`hive run #{row.project} #{row.slug} --from #{row.stage}`) " \
          "after confirming no live agent still owns the task"
      end

      def auto_recoverable_error_match_attrs(row, reason:)
        attrs = marker_attrs_for(row)
        marker_id = attrs["marker_id"].to_s
        match_attrs = { "reason" => reason }
        if marker_id.empty?
          # Match legacy no-id markers only. `clear_current` evaluates this
          # under the markers lock, so a stale row without marker_id cannot
          # clear a newer marker that gained one between status and heal.
          match_attrs["marker_id"] = nil
        else
          match_attrs["marker_id"] = marker_id
        end
        match_attrs
      end

      def observe_pre_clear_mtime(row)
        # Production always satisfies this (ConcurrencyController defines
        # the method). A future controller swap that dropped it would
        # silently reintroduce the first-sight `record_baseline` stranding
        # the seeded baseline exists to prevent — so emit a debug event
        # instead of a silent no-op, giving the gap a log signal.
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

      def error_auto_recovery_key(row, reason:)
        [
          row.project.to_s,
          row.slug.to_s,
          row.stage.to_s,
          reason.to_s
        ]
      end

      def heal_review_error_if_auto_recoverable(row)
        return if row.live_task_lock == true
        return unless auto_recoverable_review_error?(row)

        reason = marker_reason(row)
        marker_attrs = review_marker_attrs(row)
        marker_attrs["reason"] = reason
        recovery_key = review_error_auto_recovery_key(row, reason: reason)
        attempts = @review_error_auto_recoveries[recovery_key]
        if attempts >= @review_error_auto_recovery_limit
          log_recovery_exhausted_once(
            @review_error_recovery_exhausted,
            recovery_key,
            row,
            reason: review_heal_label(reason),
            marker_reason: reason,
            attempts: attempts,
            max_attempts: @review_error_auto_recovery_limit,
            phase: marker_attrs["phase"],
            pass: marker_attrs["pass"],
            errors_path: reviewer_errors_path(row),
            remediation: "rerun review for this task " \
                         "(`hive run #{row.project} #{row.slug}`) or inspect the reviewer errors file"
          )
          return
        end

        return unless Hive::Markers.clear_current(
          row.state_file,
          expected_name: :review_error,
          match_attrs: marker_attrs
        )

        attempts += 1
        @review_error_auto_recoveries[recovery_key] = attempts
        @logger.event(:marker_healed,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      prior_marker: row.marker,
                      reason: review_heal_label(reason),
                      state_file: row.state_file,
                      phase: marker_attrs["phase"],
                      pass: marker_attrs["pass"],
                      errors_path: reviewer_errors_path(row),
                      attempts: attempts,
                      max_attempts: @review_error_auto_recovery_limit)
      rescue StandardError => e
        @logger.event(:marker_heal_failed,
                      project: row.project,
                      slug: row.slug,
                      stage: row.stage,
                      reason: review_heal_label(marker_reason(row)),
                      error: "#{e.class}: #{e.message}")
      end

      # Emit `marker_heal_exhausted` at most once per (process, recovery_key).
      # The event name reads terminal, but the budget it reports is
      # in-memory and per-process: a daemon restart — or a routine SIGHUP
      # config reload, which rebuilds the healer in Dispatcher (see the
      # `@stale_agent_healer = StaleAgentHealer.new` rebuild in
      # dispatcher.rb) — drops both the retry counts AND these `seen` dedup
      # maps. So a reload re-arms `max_attempts` fresh clears and re-arms
      # this one-shot guard, which means the exhausted event can fire again
      # afterwards for the same key. `budget_scope: "per_process"` flags that
      # on the event; each call site also passes a `remediation:` hint so an
      # operator reading the log knows how to recover now instead of
      # over-reading "red forever".
      def log_recovery_exhausted_once(seen, recovery_key, row, **attrs)
        return if seen[recovery_key]

        seen[recovery_key] = true
        @logger.event(:marker_heal_exhausted,
                      **{
                        project: row.project,
                        slug: row.slug,
                        stage: row.stage,
                        prior_marker: row.marker,
                        state_file: row.state_file,
                        budget_scope: "per_process",
                        suggested_next_action: "manual_fix"
                      }.merge(attrs))
      end

      # The marker's own `reason=` attribute, the single source the
      # finalize and review auto-recovery paths both key recovery budgets
      # and match-attrs off of.
      def marker_reason(row)
        marker_attrs_for(row)["reason"].to_s
      end

      # Map a review marker reason to the healer's `reason:` log label.
      # `review_agent_died` keeps its own label; every other
      # auto-recoverable review reason (today only the tmux-death subset
      # of `reviewer_partial_failure`) logs as
      # `reviewer_tmux_session_terminated`. The marker's literal reason is
      # carried separately as `marker_reason:`.
      def review_heal_label(reason)
        reason == "review_agent_died" ? "review_agent_died" : "reviewer_tmux_session_terminated"
      end

      def review_error_auto_recovery_key(row, reason:)
        attrs = marker_attrs_for(row)
        [
          row.project.to_s,
          row.slug.to_s,
          reason.to_s,
          attrs["phase"].to_s,
          attrs["pass"].to_s,
          review_error_signature(row, reason: reason)
        ]
      end

      def review_error_signature(row, reason:)
        return reason.to_s unless reason.to_s == "reviewer_partial_failure"

        path = reviewer_errors_path(row)
        return reason.to_s unless path

        Digest::SHA256.hexdigest(File.read(path))
      rescue SystemCallError
        reason.to_s
      end

      def auto_recoverable_review_error?(row)
        attrs = marker_attrs_for(row)
        return true if attrs["reason"].to_s == "review_agent_died"

        return false unless attrs["phase"].to_s == "reviewers"
        return false unless attrs["reason"].to_s == "reviewer_partial_failure"
        return false if attrs["pass"].to_s.empty?

        path = reviewer_errors_path(row)
        return false unless path

        lines = File.readlines(path, chomp: true).grep(/\A- \[/)
        return false if lines.empty?

        lines.all? do |line|
          line.include?("tmux_session_terminated before writing expected output file")
        end
      rescue SystemCallError
        false
      end

      def reviewer_errors_path(row)
        attrs = marker_attrs_for(row)
        pass = Integer(attrs["pass"], exception: false)
        return nil unless pass

        File.join(row.folder.to_s, "reviews", "errors-#{format('%02d', pass)}.md")
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
      # drop the lock, and clear the marker so the daemon retries review.
      def heal_wedged_review_row(row)
        return unless row.claude_pid_alive == false

        holder = task_lock_holder(row)
        return unless wedged_review_lock_holder?(holder)

        marker_attrs = review_marker_attrs(row)
        return unless Hive::Markers.clear_current(
          row.state_file,
          expected_name: :review_working,
          match_attrs: marker_attrs
        )

        terminate_lock_holder(holder)
        release_task_lock(row)
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
      # dispatches) — clear the marker and drop any stale .lock so the
      # daemon re-dispatches review under normal concurrency control.
      def heal_orphaned_review_row(row, now:)
        mtime = row.state_file_mtime
        return unless mtime && (now - mtime) > @grace_sec

        marker_attrs = review_marker_attrs(row)
        return unless Hive::Markers.clear_current(
          row.state_file,
          expected_name: :review_working,
          match_attrs: marker_attrs
        )

        release_task_lock(row)
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
        out = {}
        out["phase"] = attrs["phase"] if attrs["phase"]
        out["pass"] = attrs["pass"] if attrs["pass"]
        out
      end

      def marker_attrs_for(row)
        return {} unless row.respond_to?(:marker_attrs)
        return row.marker_attrs if row.marker_attrs.is_a?(Hash)

        {}
      end

      def pid_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
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

        Process.kill("TERM", pid)
        deadline = Time.now + 1
        while Time.now < deadline
          return unless pid_alive?(pid)

          sleep 0.05
        end
        Process.kill("KILL", pid) if pid_alive?(pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def release_task_lock(row)
        File.delete(File.join(row.folder.to_s, ".lock"))
      rescue Errno::ENOENT
        nil
      rescue SystemCallError
        # The marker heal has already succeeded by the time we drop the
        # lock. A stale .lock we cannot delete (EACCES, EROFS, EISDIR, …)
        # is non-fatal residue, not a failed heal — swallow it so it does
        # not propagate to the caller's rescue and mislabel a succeeded
        # heal as `marker_heal_failed` (which would also suppress the
        # `marker_healed` success event). A later tick or the next
        # dispatch reconciles the leaked lock.
        nil
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
