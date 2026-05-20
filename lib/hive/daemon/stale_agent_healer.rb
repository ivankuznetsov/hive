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
    # the per-task .lock file):
    #
    #   - `agent_died`     — marker carried a PID (claude_pid_alive ==
    #                        false). The agent was running and exited
    #                        without rewriting its own marker (SIGKILL,
    #                        OOM, crash, hard reboot).
    #   - `agent_orphaned` — marker had no PID (claude_pid_alive == nil)
    #                        and the marker's state-file mtime is older
    #                        than the grace window. Either the daemon
    #                        never dispatched the stage (the bug that
    #                        produced this healer), or the dispatch
    #                        process died before recording its PID.
    #
    # Skip cases:
    #   - controller.running_task? returns true (an in-process dispatch
    #     is live; do not race it)
    #   - project's legacy_stage_dirs is non-empty (we never touch markers
    #     in a half-migrated layout — the dispatcher already refuses to
    #     advance these)
    #   - placeholder marker still within grace (slow but normal dispatch)
    class StaleAgentHealer
      def initialize(controller:, logger:, grace_sec: 300, clock: Time)
        @controller = controller
        @logger = logger
        @grace_sec = grace_sec
        @clock = clock
      end

      # Walk the row set, heal stale agent_working markers in place.
      # `legacy_layout_projects` is a Set/Hash of project names whose
      # status payload reported half-migrated stage dirs — we refuse to
      # touch markers in those projects.
      def heal(rows, legacy_layout_projects: {})
        rows.each do |row|
          next unless row.action == "agent_running"
          next if legacy_layout_projects.include?(row.project)
          next if @controller.running_task?(project: row.project, slug: row.slug)

          reason = classify_stale(row)
          next unless reason

          heal_row(row, reason: reason)
        end
      end

      private

      def classify_stale(row)
        case row.claude_pid_alive
        when false
          :agent_died
        when nil
          mtime = row.state_file_mtime
          return nil unless mtime

          (@clock.now - mtime) > @grace_sec ? :agent_orphaned : nil
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
