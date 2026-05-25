require "hive/markers"

module Hive
  module Daemon
    # Tick-time healer for AGENT_WORKING markers whose backing agent
    # isn't actually alive. Rewrites stale markers to ERROR with a
    # `reason` attribute so the existing red-status surface in
    # Hive::TaskAction kicks in and the disk truth stops lying.
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
      # Closed set of reason= attribute values the healer writes onto
      # ERROR markers. Consumers (TaskAction's synthetic diagnostic,
      # bot/notification rendering, future docs) can reference this
      # constant instead of hard-coding the literal strings.
      REASONS = %i[agent_died agent_orphaned].freeze

      def initialize(controller:, logger:, grace_sec: 300)
        @controller = controller
        @logger = logger
        @grace_sec = grace_sec
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
          next unless row.marker.to_s == "agent_working"
          next if legacy_layout_projects.include?(row.project)
          next if @controller.running_task?(project: row.project, slug: row.slug)
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
