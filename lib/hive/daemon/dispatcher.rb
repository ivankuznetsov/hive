require "hive/config"
require "hive/daemon/policy"
require "hive/daemon/concurrency_controller"
require "hive/daemon/child_supervisor"
require "hive/daemon/status_consumer"
require "hive/daemon/logger"

module Hive
  module Daemon
    # The poll-classify-dispatch loop. Glues the pure pieces (Policy,
    # ConcurrencyController) to the I/O pieces (StatusConsumer,
    # ChildSupervisor, Logger) and a PrMergeWatcher (if injected).
    #
    # Each `tick` is one round: reap completed children, fetch status,
    # decide per row, dispatch where allowed. The poller calls `tick` at
    # `daemon.poll_interval_sec` cadence; signals (TERM/INT/HUP) drive
    # graceful shutdown / config reload.
    class Dispatcher
      attr_reader :controller, :supervisor, :logger

      # @param config [Hash] merged config (Hive::Config.load) — used for
      #   the `daemon` block defaults; per-project enrollment is read from
      #   each project's own config via Hive::Config.load(project_root).
      # @param controller [ConcurrencyController]
      # @param supervisor [ChildSupervisor]
      # @param status_consumer [StatusConsumer]
      # @param logger [Hive::Daemon::Logger]
      # @param merge_watcher [PrMergeWatcher, nil]
      # @param dry_run [Boolean]
      def initialize(config:, controller:, supervisor:, status_consumer:, logger:,
                     merge_watcher: nil, dry_run: false)
        @config = config
        @controller = controller
        @supervisor = supervisor
        @status_consumer = status_consumer
        @logger = logger
        @merge_watcher = merge_watcher
        @dry_run = dry_run

        @daemon_cfg = config["daemon"] || {}
        @edit_debounce_sec = @daemon_cfg.fetch("edit_debounce_sec", 30)
        @shutdown_grace_sec = @daemon_cfg.fetch("shutdown_grace_sec", 600)
        @poll_interval_sec = @daemon_cfg.fetch("poll_interval_sec", 30)

        @shutdown = false
        @reload = false
        @started_at = nil
        @last_tick_at = nil
        @dispatched_today = 0
        # Per-project enable cache, refreshed on tick to pick up YAML edits.
        @enabled_cache = {}
      end

      # Single tick: reap, fetch, dispatch. Pure dispatcher — no signal
      # handling, no sleep. Public so tests can drive a single tick
      # deterministically.
      def tick(now: Time.now)
        @last_tick_at = now
        @logger.event(:tick_begin, now: now.utc.iso8601)

        # 1. Reap completed children, update controller, log decisions
        reap_completed(now: now)

        # 1b. Reap dry-run pseudo-children if dry-run mode
        reap_dry_run(now: now) if @dry_run

        # 2. Fetch status
        result = @status_consumer.fetch
        unless result.ok
          @logger.event(:status_failure, error: result.error)
          @logger.event(:tick_end, now: Time.now.utc.iso8601, action: "status_failure")
          return
        end

        # 3. PrMergeWatcher tick (if present): check pending merges first
        @merge_watcher&.tick(now: now)&.each do |archive_dispatch|
          dispatch_command(archive_dispatch[:command],
                           project: archive_dispatch[:project],
                           slug: archive_dispatch[:slug],
                           stage: archive_dispatch[:stage],
                           state_file_mtime: archive_dispatch[:state_file_mtime],
                           hive_state_path: archive_dispatch[:hive_state_path],
                           now: now)
        end

        # 4. Per-row dispatch
        result.rows.each { |row| handle_row(row, now: now) }

        @logger.event(:tick_end, now: Time.now.utc.iso8601,
                                 in_flight: @controller.in_flight_count)
      end

      # Run forever: install signal traps, loop tick + interruptible
      # sleep, and graceful shutdown on TERM/INT.
      def run_forever
        install_signal_handlers!
        @started_at = Time.now
        @logger.event(:dispatcher_started, version: Hive::VERSION,
                                           dry_run: @dry_run, pid: Process.pid)

        until @shutdown
          if @reload
            reload_config!
            @reload = false
          end
          tick
          interruptible_sleep(@poll_interval_sec)
        end

        @logger.event(:dispatcher_stopping, in_flight: @controller.in_flight_count,
                                            grace_sec: @shutdown_grace_sec)
        @supervisor.terminate_all(grace_sec: @shutdown_grace_sec)
        # One final reap to catch any last completions
        reap_completed(now: Time.now)
        @logger.close
      end

      def request_shutdown!
        @shutdown = true
      end

      def request_reload!
        @reload = true
      end

      private

      def reap_completed(now:)
        @supervisor.reap_all(now: now).each do |entry|
          @controller.record_completion(
            pid: entry.pid, exit_code: entry.exit_code, completed_at: now
          )
          @logger.event(:child_exited,
                        pid: entry.pid, exit_code: entry.exit_code,
                        project: entry.project, slug: entry.slug, stage: entry.stage,
                        elapsed_sec: (now - entry.started_at).to_i,
                        envelope_marker: entry.json_envelope&.dig("marker"),
                        envelope_ok: entry.json_envelope&.dig("ok"))
          @controller.record_project_dropped(project: entry.project) if entry.exit_code == Hive::ExitCodes::CONFIG
          if entry.exit_code == Hive::ExitCodes::CONFIG
            @logger.event(:project_dropped, project: entry.project)
          end
        end
      end

      def reap_dry_run(now:)
        @supervisor.reap_dry_run(now: now).each do |entry|
          @controller.record_completion(
            pid: entry.pid, exit_code: entry.exit_code, completed_at: now
          )
          @logger.event(:child_exited,
                        pid: entry.pid, exit_code: entry.exit_code,
                        project: entry.project, slug: entry.slug, stage: entry.stage,
                        dry_run: true, elapsed_sec: 0)
        end
      end

      def handle_row(row, now:)
        return unless project_enabled?(row.project)

        decision = Policy.decide(
          action: row.action,
          command: row.suggested_command,
          state_file_mtime: row.state_file_mtime,
          last_dispatched_state_file_mtime:
            @controller.last_dispatched_state_file_mtime_for(project: row.project, slug: row.slug),
          now: now,
          edit_debounce_sec: @edit_debounce_sec
        )

        case decision
        when :dispatch
          dispatch_or_block(row, now: now)
        when :wait_for_debounce
          @logger.event(:debouncing, project: row.project, slug: row.slug,
                                     stage: row.stage, mtime: row.state_file_mtime&.utc&.iso8601)
        when :poll_for_merge
          enqueue_merge_watch(row)
        when :skip
          @logger.event(:skipped, project: row.project, slug: row.slug,
                                  stage: row.stage, action: row.action)
        end
      end

      def dispatch_or_block(row, now:)
        gate = @controller.can_dispatch?(project: row.project, slug: row.slug, now: now)
        if gate == :ok
          dispatch_command(
            row.suggested_command,
            project: row.project, slug: row.slug, stage: row.stage,
            state_file_mtime: row.state_file_mtime,
            hive_state_path: nil, # supervisor falls back to tmpdir
            now: now
          )
        else
          @logger.event(:blocked, project: row.project, slug: row.slug,
                                  stage: row.stage, reason: gate.to_s)
        end
      end

      def dispatch_command(command, project:, slug:, stage:, state_file_mtime:,
                           hive_state_path:, now:)
        if @dry_run
          @logger.event(:dry_run, project: project, slug: slug, stage: stage,
                                  command: command)
        end
        pid = @supervisor.spawn(
          command_string: command,
          project: project, slug: slug, stage: stage,
          hive_state_path: hive_state_path,
          dry_run: @dry_run
        )
        @controller.record_dispatch(
          pid: pid, project: project, slug: slug, stage: stage,
          command: command, started_at: now, state_file_mtime: state_file_mtime
        )
        @logger.event(:dispatched, pid: pid, project: project, slug: slug,
                                   stage: stage, command: command, dry_run: @dry_run)
        @dispatched_today += 1
      end

      def enqueue_merge_watch(row)
        return unless @merge_watcher

        @merge_watcher.enqueue(project: row.project, slug: row.slug,
                               task_folder: row.folder)
        @logger.event(:merge_watcher_enqueued, project: row.project, slug: row.slug,
                                               folder: row.folder)
      end

      def project_enabled?(project_name)
        return @enabled_cache[project_name] if @enabled_cache.key?(project_name)

        # Look up the project's path from the global registry, then
        # Config.load(project_path) to read per-project daemon.enabled.
        entry = Hive::Config.find_project(project_name)
        if entry.nil?
          @enabled_cache[project_name] = false
          return false
        end

        cfg = Hive::Config.load(entry["path"])
        @enabled_cache[project_name] = cfg.dig("daemon", "enabled") == true
      rescue Hive::ConfigError
        @enabled_cache[project_name] = false
      end

      def reload_config!
        @config = Hive::Config.send(:merge_defaults, {}) # rebase on bare DEFAULTS for safety
        @daemon_cfg = @config["daemon"] || {}
        @edit_debounce_sec = @daemon_cfg.fetch("edit_debounce_sec", 30)
        @shutdown_grace_sec = @daemon_cfg.fetch("shutdown_grace_sec", 600)
        @poll_interval_sec = @daemon_cfg.fetch("poll_interval_sec", 30)
        @enabled_cache.clear
        @logger.event(:config_reloaded)
      end

      def install_signal_handlers!
        Signal.trap("TERM") { @shutdown = true }
        Signal.trap("INT")  { @shutdown = true }
        Signal.trap("HUP")  { @reload = true }
      end

      def interruptible_sleep(seconds)
        deadline = Time.now + seconds
        while Time.now < deadline && !@shutdown && !@reload
          sleep 0.5
        end
      end
    end
  end
end
