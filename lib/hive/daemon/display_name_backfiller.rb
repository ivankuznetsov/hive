require "fileutils"
require "hive/paths"
require "hive/task_meta"

module Hive
  module Daemon
    # Tick-time self-healer for tasks whose `display_name` never got set.
    #
    # Name generation today is a one-shot fire-and-forget spawn at
    # `hive new` (see Hive::Commands::New#spawn_name_generator) with no
    # retry. If that spawn fails — typically because the agent/codex
    # backend is rate-limited or down during a `hive new` — the task is
    # left showing its raw slug forever, since nothing ever re-attempts
    # name generation.
    #
    # This backfiller closes that gap purely additively: on each tick it
    # scans the status rows, and for any task whose `meta.yml`
    # `display_name` is still nil/empty it re-spawns
    # `hive generate-name <folder>` using the exact same detached,
    # logged, fully-rescued fire-and-forget pattern as `new.rb`. It never
    # touches markers, dispatch, or heal logic.
    #
    # Anti-churn design:
    #   - Once a task's name is set, the next status read no longer flags
    #     it (the meta read returns a present display_name), so it is a
    #     natural fixed point — no marker write, no state to reconcile.
    #   - `@inflight` (folder => pid) prevents double-spawning while a
    #     generate-name child is still running; finished pids are reaped
    #     non-blockingly at the top of every `backfill`.
    #   - `max_per_tick` bounds how many fresh spawns a single tick may
    #     start, so a large backlog (e.g. after an outage) drains over
    #     several ticks instead of fork-bombing the host.
    #   - A failure (backend still limited, generate-name errors) simply
    #     leaves display_name unset; the row is flagged again on a later
    #     tick and retried. There is no backoff — the tick interval is
    #     the only spacing — which is acceptable for a cosmetic backfill.
    class DisplayNameBackfiller
      DEFAULT_MAX_PER_TICK = 2

      def initialize(logger:, dry_run: false, spawn: nil, max_per_tick: DEFAULT_MAX_PER_TICK)
        @logger = logger
        @dry_run = dry_run
        @spawn = spawn || method(:spawn_name_generator)
        @max_per_tick = max_per_tick
        @inflight = {}
      end

      # Walk the row set; for each task with a missing display_name that
      # isn't already being regenerated, fire-and-forget a
      # `hive generate-name`. `now:` matches the convention used by every
      # other daemon component so a single tick observes one frozen clock.
      def backfill(rows, now: Time.now)
        _ = now
        reap_inflight
        spawned = 0
        rows.each do |row|
          break if spawned >= @max_per_tick

          spawned += 1 if consider_row(row)
        end
      rescue StandardError => e
        # Belt-and-suspenders: even though every per-row step is itself
        # rescued, an unexpected failure anywhere in the loop must never
        # raise out of backfill (the dispatcher wraps this too, but the
        # local guard keeps the no-op contract self-contained).
        @logger.event(:fatal,
                      message: "display_name_backfiller#backfill raised: #{e.class}: #{e.message}",
                      keeping_previous: true)
      end

      private

      # Returns true only when a fresh spawn was started this tick (so
      # the caller can count it against max_per_tick). A single bad row
      # or meta is swallowed here so the rest of the row set still runs.
      def consider_row(row)
        folder = row_folder(row)
        return false if folder.nil? || folder.empty?
        return false if @inflight.key?(folder)
        return false unless display_name_missing?(folder)

        backfill_row(row, folder)
      rescue StandardError => e
        @logger.event(:fatal,
                      message: "display_name_backfiller row raised: #{e.class}: #{e.message}",
                      keeping_previous: true)
        false
      end

      # Drop inflight entries whose generate-name child has exited.
      #
      # Liveness is decided by `Process.kill(0, pid)`, not by
      # `Process.wait`: the internal spawn (mirroring new.rb) starts a
      # detached waiter thread that reaps the child itself, so a
      # competing non-blocking `wait` here would race it and usually hit
      # ECHILD — which would wrongly drop a still-running child and let
      # us double-spawn. `kill(0)` only reports actual process liveness:
      # ESRCH means the pid is gone (drop it), EPERM means alive but not
      # ours (keep it). A best-effort non-blocking `wait` is still issued
      # to clear any zombie we ourselves own, but its result never
      # decides inflight membership.
      def reap_inflight
        @inflight.delete_if do |_folder, pid|
          alive = pid_alive?(pid)
          reap_zombie(pid) unless alive
          !alive
        rescue StandardError
          false
        end
      end

      def pid_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def reap_zombie(pid)
        Process.wait(pid, Process::WNOHANG)
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end

      def display_name_missing?(folder)
        name = Hive::TaskMeta.read(folder)[:display_name]
        name.nil? || name.to_s.strip.empty?
      rescue StandardError
        # If we can't read the meta we can't tell — treat as "not
        # missing" so a flaky read never triggers a spawn storm.
        false
      end

      def backfill_row(row, folder)
        if @dry_run
          @logger.event(:display_name_backfill,
                        project: row.project,
                        slug: row.slug,
                        folder: folder,
                        pid: nil,
                        dry_run: true)
          return false
        end

        pid = @spawn.call(folder)
        return false if pid.nil?

        @inflight[folder] = pid
        @logger.event(:display_name_backfill,
                      project: row.project,
                      slug: row.slug,
                      folder: folder,
                      pid: pid)
        true
      rescue StandardError => e
        @logger.event(:fatal,
                      message: "display_name_backfiller spawn raised: #{e.class}: #{e.message}",
                      keeping_previous: true)
        false
      end

      def row_folder(row)
        return nil unless row.respond_to?(:folder)

        row.folder.to_s
      end

      # Mirror Hive::Commands::New#spawn_name_generator exactly: detached
      # `hive generate-name <folder>` in its own process group, stdout +
      # stderr appended to the shared display-name log, with a detached
      # waiter thread so the child can't become a zombie, and the whole
      # thing rescued so a spawn failure is a silent nil (the next tick
      # retries). Returns the pid or nil.
      def spawn_name_generator(folder)
        FileUtils.mkdir_p(File.join(Hive::Paths.state_home, "logs"))
        log_path = File.join(Hive::Paths.state_home, "logs", "display-name.log")
        pid = Process.spawn(
          ENV.fetch("HIVE_BIN", "hive"), "generate-name", folder,
          pgroup: true,
          out: [ log_path, "a" ],
          err: [ log_path, "a" ]
        )
        Thread.new do
          Thread.current.report_on_exception = false
          Process.wait(pid)
        rescue Errno::ECHILD, Errno::ESRCH
          nil
        end
        pid
      rescue StandardError
        nil
      end
    end
  end
end
