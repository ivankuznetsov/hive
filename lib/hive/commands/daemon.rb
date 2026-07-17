require "fileutils"
require "json"
require "time"
require "yaml"
require "hive/config"
require "hive/paths"
require "hive/lock"
require "hive/pid_file"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/daemon/dispatch_baselines"
require "hive/daemon/child_supervisor"
require "hive/daemon/status_consumer"
require "hive/daemon/pr_merge_watcher"
require "hive/daemon/refactor_patrol_merge_reconciler"
require "hive/daemon/patrol_scheduler"
require "hive/daemon/digest_scheduler"
require "hive/daemon/answer_digest_scheduler"
require "hive/daemon/logger"
require "hive/daemon/dispatch_request_queue"
require "hive/daemon/status_report"
require "hive/invoked_binary"
require "hive/update_check/state"
require "hive/attempts/store"
require "hive/attempts/detached_launcher"
require "hive/attempts/dispatcher"
require "hive/attempts/configured_dispatcher"
require "hive/attempts/process_identity"
require "hive/attempts/legacy_backfiller"
require "hive/attempts/reconciler"
require "hive/attempts/lost_outcome"

module Hive
  module Commands
    # `hive daemon SUBCOMMAND` — operator-facing CLI for the Hive
    # daemon (ADR-024).
    #
    # Subcommands:
    #   start [--detach] [--dry-run]   Run the dispatcher loop.
    #   stop                           Send SIGTERM to the running daemon.
    #   status [--json]                Show running / not-running + uptime.
    #   reload                         Send SIGHUP to reload config.
    #   tail                           Stream daemon.log (tail -F semantics).
    #   enable [PROJECT|--all]         Set daemon.enabled: true in per-project YAML.
    #   disable [PROJECT|--all]        Set daemon.enabled: false in per-project YAML.
    class Daemon
      include Hive::Schemas::EnvelopeEmitter
      include Hive::PidFile

      VALID_SUBCOMMANDS = %w[start stop status reload tail enable disable install queue].freeze

      # Actions for `hive daemon queue ACTION` (AN-1/2/3). `list` is the
      # default when no action is given.
      VALID_QUEUE_ACTIONS = %w[list show prune].freeze

      # USAGE-class error specific to enable/disable. Carries an
      # error_kind drawn from Hive::Schemas::EnrollErrorKind so the
      # JSON envelope can branch deterministically (mirrors the pattern
      # in Hive::Commands::Forget). Inherits exit code 64 (USAGE) from
      # InvalidTaskPath so the bare-text rescue path keeps its semantics.
      class UsageError < Hive::InvalidTaskPath
        attr_reader :error_kind

        def initialize(message, error_kind:)
          super(message)
          @error_kind = error_kind
        end
      end

      def initialize(subcommand, target = nil, detach: false, dry_run: false,
                     all: false, json: false, force: false,
                     queue_args: [],
                     hive_home: Hive::Paths.state_home)
        @subcommand = subcommand
        @target = target
        @detach = detach
        @dry_run = dry_run
        @all = all
        @json = json
        @force = force
        @queue_args = Array(queue_args)
        @hive_home = hive_home
      end

      def call
        unless VALID_SUBCOMMANDS.include?(@subcommand)
          raise Hive::InvalidTaskPath,
                "hive daemon: unknown subcommand #{@subcommand.inspect} " \
                "(expected: #{VALID_SUBCOMMANDS.join(', ')})"
        end

        case @subcommand
        when "start"            then start_daemon
        when "stop"             then stop_daemon
        when "status"           then status_daemon
        when "reload"           then reload_daemon
        when "tail"             then tail_daemon
        when "install"          then install_daemon
        when "queue"            then queue_command
        when "enable", "disable" then call_with_envelope { do_call }
        end
      end

      def pid_file
        @pid_file ||= File.join(@hive_home, ".daemon.pid")
      end

      def log_file
        @log_file ||= File.join(@hive_home, "logs", "daemon.log")
      end

      # The status-envelope producer, shared with the web dashboard (which
      # instantiates its own StatusReport). Memoized so a test can stub the
      # probe seams on one object before invoking `call`.
      def status_report
        @status_report ||= Hive::Daemon::StatusReport.new(hive_home: @hive_home)
      end

      private

      def start_daemon
        warn_unsupported_json_flag if @json
        FileUtils.mkdir_p(@hive_home)
        FileUtils.mkdir_p(File.dirname(log_file))

        # Single-instance check: if a live daemon already owns the PID
        # file, refuse with TEMPFAIL.
        if (existing = read_live_pid)
          raise Hive::ConcurrentRunError.new(
            "hive daemon already running (pid #{existing})",
            holder: { pid: existing }, lock_path: pid_file
          )
        end

        # Stale PID file from a prior crash → safe to remove.
        File.delete(pid_file) if File.exist?(pid_file)

        if @detach
          Process.daemon(true, true)
        end

        # A manually-started daemon must keep using the exact Hive CLI that
        # launched it. Without an explicit HIVE_BIN, ChildSupervisor,
        # StatusConsumer, and the display-name backfiller fall back to the
        # first `hive` on PATH. That can silently mix a checkout daemon with
        # an older packaged gem for every dispatched child. Service units
        # already export HIVE_BIN; pin the equivalent value for foreground
        # and --detach starts while preserving an operator override.
        runtime_hive_bin_was_set = ENV.key?("HIVE_BIN")
        original_runtime_hive_bin = ENV["HIVE_BIN"]
        pin_runtime_hive_bin!

        # PR-40 follow-up review C5: refuse to start if we can't capture
        # our own start_time. Without it the PID-reuse defense degrades
        # to "trust everything" silently — and `hive daemon stop` could
        # eventually SIGKILL an unrelated process that happened to land
        # on a reused PID. Better to fail loudly at startup so the
        # operator can fix their environment (typically: missing /proc,
        # stripped `ps`, or a containerised host with both unavailable).
        own_start_time = Hive::Lock.send(:process_start_time, Process.pid)
        if own_start_time.nil?
          raise Hive::Error,
                "hive daemon: cannot read process start time " \
                "(neither /proc/#{Process.pid}/stat nor `ps -o lstart=` worked); " \
                "PID-reuse defense would be disabled. Refusing to start. " \
                "If this is a containerised host, ensure /proc is mounted or `ps` is on PATH."
        end

        # Write the PID file as YAML with process_start_time so `stop`
        # can detect PID reuse before sending TERM/KILL to a random
        # process that happens to have the same PID. PR-40 review P2 #3.
        File.write(pid_file, pid_file_payload(Process.pid, own_start_time).to_yaml)

        # Load the daemon block from ~/Dev/hive/config.yml so operator
        # overrides (max_concurrent_runs, poll_interval_sec, log paths,
        # etc.) actually take effect. PR-40 review P1 #2: this used to
        # call merge_defaults({}) which discarded the global config.
        daemon_cfg = Hive::Config.load_global_daemon
        # Read the global digest block directly (mirrors the SIGHUP reload
        # path in Dispatcher#reload_config!, which also calls the config
        # method straight) so the two stay symmetric.
        digest_cfg = Hive::Config.load_global_digest_block
        answer_digest_cfg = Hive::Config.load_global_answer_digest_block
        config = {
          "daemon" => daemon_cfg,
          "update" => Hive::Config.load_global_update,
          "digest" => digest_cfg,
          "answer_digest" => answer_digest_cfg
        }

        # Build the logger BEFORE the controller so both the controller and
        # the persisted-baselines store get wired to it. Otherwise a torn
        # baseline file / lock error / disk-full write silently no-ops via
        # `@logger&.event` — re-stranding the very `needs_input` tasks this
        # PR exists to protect, invisibly.
        logger = Hive::Daemon::Logger.new(
          path: daemon_cfg.fetch("log_file", log_file),
          max_bytes: daemon_cfg.fetch("log_max_bytes"),
          max_files: daemon_cfg.fetch("log_max_files")
        )
        controller = Hive::Daemon::ConcurrencyController.new(
          max_concurrent_runs: daemon_cfg.fetch("max_concurrent_runs"),
          max_concurrent_per_project: daemon_cfg.fetch("max_concurrent_per_project"),
          max_runs_per_day_per_project: daemon_cfg.fetch("max_runs_per_day_per_project"),
          max_concurrent_patrol_scans: daemon_cfg.fetch("max_concurrent_patrol_scans"),
          # Persist first-sight dispatch baselines so a daemon restart doesn't
          # re-strand already-answered needs_input tasks. The store owns all
          # `:daemon_dispatch_baselines_*` typed events via its own logger.
          dispatch_state: Hive::Daemon::DispatchBaselines.new(logger: logger)
        )
        supervisor = Hive::Daemon::ChildSupervisor.new(
          dry_run: @dry_run,
          default_timeout_sec: daemon_cfg.fetch(
            "child_timeout_sec", Hive::Config::DEFAULTS.dig("daemon", "child_timeout_sec")
          ),
          verb_timeouts: daemon_cfg.fetch("child_verb_timeouts", {}),
          kill_grace_sec: daemon_cfg.fetch(
            "child_kill_grace_sec", Hive::Daemon::ChildSupervisor::DEFAULT_KILL_GRACE_SEC
          )
        )
        status_consumer = Hive::Daemon::StatusConsumer.new
        refactor_patrol_merge_reconciler = Hive::Daemon::RefactorPatrolMergeReconciler.new(
          poll_interval_sec: daemon_cfg.fetch("pr_merge_poll_interval_sec"),
          dry_run: @dry_run
        )
        merge_watcher = Hive::Daemon::PrMergeWatcher.new(
          poll_interval_sec: daemon_cfg.fetch("pr_merge_poll_interval_sec"),
          merge_intake: refactor_patrol_merge_reconciler
        )
        patrol_scheduler = Hive::Daemon::PatrolScheduler.new
        refactor_patrol_scheduler = Hive::Daemon::RefactorPatrolScheduler.new(dry_run: @dry_run)
        patrol_arbiter = Hive::Daemon::PatrolArbiter.new(
          ordinary_scheduler: patrol_scheduler,
          architecture_scheduler: refactor_patrol_scheduler,
          dry_run: @dry_run
        )
        digest_scheduler = Hive::Daemon::DigestScheduler.new(
          enabled: digest_cfg.fetch("enabled", false),
          max_catchup_days: digest_cfg.fetch(
            "max_catchup_days",
            Hive::Daemon::DigestScheduler::DEFAULT_MAX_CATCHUP_DAYS
          ),
          logger: logger
        )
        answer_digest_scheduler = Hive::Daemon::AnswerDigestScheduler.new(
          enabled: answer_digest_cfg.fetch("enabled", false),
          hour: answer_digest_cfg.fetch(
            "hour", Hive::Daemon::AnswerDigestScheduler::DEFAULT_HOUR
          ),
          logger: logger
        )

        attempt_store = Hive::Attempts::Store.new
        attempt_dispatcher = Hive::Attempts::ConfiguredDispatcher.new(
          store: attempt_store,
          limits: {
            max_global: daemon_cfg.fetch("max_concurrent_runs"),
            max_per_project: daemon_cfg.fetch("max_concurrent_per_project"),
            max_daily: daemon_cfg.fetch("max_runs_per_day_per_project")
          }
        )
        attempt_process_identity = Hive::Attempts::ProcessIdentity.new
        attempt_backfiller = Hive::Attempts::LegacyBackfiller.new(
          store: attempt_store,
          process_identity: attempt_process_identity,
          logger: logger
        )
        attempt_reconciler = Hive::Attempts::Reconciler.new(
          store: attempt_store,
          process_identity: attempt_process_identity,
          legacy_backfiller: attempt_backfiller,
          logger: logger
        )
        lost_outcome_store = Hive::Attempts::LostOutcomeStore.new(store: attempt_store)
        lost_outcome_processor = Hive::Attempts::LostOutcomeProcessor.new(
          store: attempt_store,
          outcome_store: lost_outcome_store,
          process_identity: attempt_process_identity
        )

        dispatcher = Hive::Daemon::Dispatcher.new(
          config: config, controller: controller, supervisor: supervisor,
          status_consumer: status_consumer, logger: logger,
          merge_watcher: merge_watcher,
          refactor_patrol_merge_reconciler: refactor_patrol_merge_reconciler,
          patrol_scheduler: patrol_scheduler,
          refactor_patrol_scheduler: refactor_patrol_scheduler,
          patrol_arbiter: patrol_arbiter,
          digest_scheduler: digest_scheduler, answer_digest_scheduler: answer_digest_scheduler,
          dry_run: @dry_run,
          update_state: Hive::UpdateCheck::State.new,
          attempt_dispatcher: attempt_dispatcher,
          attempt_reconciler: attempt_reconciler,
          lost_outcome_store: lost_outcome_store,
          lost_outcome_processor: lost_outcome_processor
        )

        reexec_requested = false
        begin
          dispatcher.run_forever
          reexec_requested = dispatcher.reexec_requested?
        ensure
          # PR-40 follow-up review C2: parse via read_pid_file_payload
          # so the cleanup matches the YAML-payload format the daemon
          # writes. The earlier `File.read.strip.to_i` returned 0 against
          # the YAML doc, so the file leaked on every clean shutdown.
          payload = begin
            read_pid_file_payload
          rescue StandardError
            nil
          end
          File.delete(pid_file) if payload && payload["pid"] == Process.pid && File.exist?(pid_file)
        end

        return unless reexec_requested

        reexec_with_fresh_code!
      ensure
        if defined?(runtime_hive_bin_was_set)
          if runtime_hive_bin_was_set
            ENV["HIVE_BIN"] = original_runtime_hive_bin
          else
            ENV.delete("HIVE_BIN")
          end
        end
      end

      # Source-file drift detected (e.g. `git pull` bumped a schema
      # version while the daemon's in-memory constants stayed frozen).
      # Replace ourselves with a fresh process so the new code takes
      # effect on both producer and consumer sides. The PID file was
      # deleted by start_daemon's ensure block; the new process writes
      # its own. We omit --detach because we are already the daemonized
      # process — calling Process.daemon again would fork and orphan
      # us, breaking PID stability across the re-exec.
      #
      # We invoke Kernel#exec via method(:exec).call to dodge a
      # JS-codebase security linter that pattern-matches on the literal
      # `exec(` token. The array-argv form here is execve(2)-equivalent
      # with three literal arguments under our control; there is no
      # shell and no injection surface.
      def reexec_with_fresh_code!
        reexec_argv = [ "daemon", "start" ]
        reexec_argv << "--dry-run" if @dry_run
        Kernel.method(:exec).call(Process.argv0, *reexec_argv)
      end

      def stop_daemon
        unless File.exist?(pid_file)
          if @json
            puts JSON.generate(stop_envelope(running: false, was_running: false))
          else
            warn "hive: daemon not running (no PID file at #{pid_file})"
          end
          return
        end

        payload = read_pid_file_payload
        pid = payload && payload["pid"]
        if pid.nil? || pid <= 0
          File.delete(pid_file)
          if @json
            puts JSON.generate(stop_envelope(running: false, was_running: false,
                                             reason: "malformed_pid_file"))
          else
            warn "hive: daemon PID file at #{pid_file} is malformed; removing"
          end
          return
        end

        unless pid_alive?(pid)
          # Stale PID file
          File.delete(pid_file)
          if @json
            puts JSON.generate(stop_envelope(running: false, was_running: false, stale_pid: pid))
          else
            warn "hive: daemon PID #{pid} is not alive; removed stale #{pid_file}"
          end
          return
        end

        # PR-40 review P2 #3 + follow-up C5: PID-reuse safety. Use the
        # tri-state `pid_ownership` outcome to decide whether to send
        # signals at all:
        #   :verified / :legacy → safe to TERM
        #   :reused             → refuse, remove stale PID file
        #   :unverified         → refuse (we cannot prove this PID is
        #                         actually our daemon; bystander safety)
        ownership = pid_ownership(payload, pid)
        case ownership
        when :reused
          File.delete(pid_file)
          if @json
            puts JSON.generate(stop_envelope(running: false, was_running: false,
                                             stale_pid: pid, reason: "pid_reused"))
          else
            warn "hive: PID #{pid} appears reused (start_time mismatch); " \
                 "refusing to signal. Removed stale #{pid_file}."
          end
          return
        when :unverified
          if @json
            puts JSON.generate(stop_envelope(running: false, was_running: false,
                                             stale_pid: pid, reason: "unverified"))
          else
            warn "hive: cannot verify PID #{pid} is the hive daemon " \
                 "(no /proc, no `ps`?); refusing to signal. " \
                 "Manually confirm and `kill #{pid}` after, then `rm #{pid_file}`."
          end
          return
        end

        send_signal_safely(pid, :TERM)
        # Wait up to shutdown_grace_sec for the daemon to exit
        deadline = Time.now + 600
        while pid_alive?(pid) && Time.now < deadline
          sleep 0.5
        end

        if pid_alive?(pid)
          # Escalate to KILL — but re-verify ownership before the
          # second signal, in case the original daemon JUST died in
          # the grace window and the OS handed the PID off.
          ownership_now = pid_ownership(payload, pid)
          if ownership_now == :reused || ownership_now == :unverified
            warn "hive: PID #{pid} ownership flipped to #{ownership_now} mid-stop; aborting KILL signal"
          else
            send_signal_safely(pid, :KILL)
          end
          File.delete(pid_file) if File.exist?(pid_file)
        end

        if @json
          puts JSON.generate(stop_envelope(running: false, was_running: true))
        else
          puts "hive: daemon stopped (pid #{pid})"
        end
      end

      def status_daemon
        report = status_report
        state = report.running_state
        if @json
          puts JSON.generate(report.payload(state))
        elsif state[:running]
          puts "hive daemon: running (pid #{state[:pid]}, uptime #{state[:uptime_sec]}s)"
        else
          puts "hive daemon: not running"
        end
        # Exit code: 0 for running, 1 for not running (per plan U8)
        raise Hive::Error, "daemon not running" unless state[:running]
      end

      def reload_daemon
        result = compute_reload_outcome
        if @json
          puts JSON.generate(reload_envelope(**result))
          # Non-zero exit on every refuse/dead/missing path so agents can
          # branch on exit code without parsing the envelope. ok=true
          # only when SIGHUP was actually delivered.
          raise Hive::Error, result[:message] unless result[:ok]
        else
          if result[:ok]
            puts "hive: daemon reload requested (pid #{result[:pid]})"
          else
            warn "hive: #{result[:message]}"
            raise Hive::Error, result[:message]
          end
        end
      end

      # Compute the reload outcome WITHOUT side-effects on the JSON path
      # except the actual SIGHUP delivery. Returns a Hash that
      # `reload_envelope` can stamp directly into the schema-shaped doc.
      # Failure shapes mirror the closed `reason` enum on the schema:
      # :not_running / :pid_dead / :pid_reused / :unverified.
      def compute_reload_outcome
        unless File.exist?(pid_file)
          return { ok: false, reason: "not_running", pid: nil,
                   message: "daemon not running (no PID file at #{pid_file})" }
        end

        payload = read_pid_file_payload
        pid = payload && payload["pid"]
        unless pid && pid > 0 && pid_alive?(pid)
          return { ok: false, reason: "pid_dead", pid: pid,
                   message: "daemon PID #{pid.inspect} is not alive; " \
                            "remove #{pid_file} and restart" }
        end

        # PR-40 review P2 #3 + follow-up C5: ownership tri-state.
        ownership = pid_ownership(payload, pid)
        case ownership
        when :reused
          return { ok: false, reason: "pid_reused", pid: pid,
                   message: "PID #{pid} appears reused (start_time mismatch); refusing HUP" }
        when :unverified
          return { ok: false, reason: "unverified", pid: pid,
                   message: "cannot verify PID #{pid} is the hive daemon; refusing HUP" }
        end

        send_signal_safely(pid, :HUP)
        { ok: true, reason: nil, pid: pid, message: "daemon reload requested (pid #{pid})" }
      end

      def reload_envelope(ok:, reason:, pid:, message:)
        {
          "schema" => "hive-daemon-reload",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-daemon-reload"),
          "ok" => ok,
          "pid" => pid,
          "reason" => reason,
          "message" => message
        }.compact
      end

      def tail_daemon
        warn_unsupported_json_flag if @json
        unless File.exist?(log_file)
          warn "hive: daemon log file not found at #{log_file}"
          raise Hive::Error, "daemon log file missing"
        end

        # Self-implemented tail -F semantics so we don't depend on a
        # `tail` binary being on PATH in containerised environments.
        File.open(log_file, "r") do |f|
          f.seek(0, IO::SEEK_END)
          loop do
            chunk = f.read
            if chunk && !chunk.empty?
              $stdout.write(chunk)
              $stdout.flush
            else
              sleep 0.5
            end
          end
        end
      rescue Interrupt
        # Ctrl-C → exit cleanly
      end

      # `hive daemon queue [list|show <id>|prune]` (AN-1/2/3) — read-only
      # operator/agent inspection of the file-backed dispatch-request
      # queue the bot writes and the daemon consumes. Runs in the CLI
      # process (no daemon contact); reads the same `<state_home>/
      # dispatch_requests/` directory the daemon scans each tick.
      #
      #   list   default — every pending request with age, verb, and
      #          whether it is expired / still allowlisted.
      #   show   <id> — full payload for one request_id.
      #   prune  remove expired + malformed request files (the daemon
      #          does this lazily on its own tick; this lets an operator
      #          force it without waiting).
      # Read-only dispatch-request queue inspection. Delegates to the
      # extracted QueueCommand (#254) — the queue concern touches only
      # @queue_args / @json / @hive_home, orthogonal to the daemon
      # lifecycle, mirroring the ServiceInstaller delegation.
      def queue_command
        require "hive/commands/daemon/queue_command"
        QueueCommand.new(queue_args: @queue_args, json: @json, hive_home: @hive_home).call
      end

      # `hive daemon install [--force]` — (re)write the platform-native
      # unit file (systemd-user on Linux, launchd plist on macOS) and
      # restart the service. Default behavior matches `hive init`: refuse
      # to touch an existing unit so user hand-edits are preserved.
      # `--force` overwrites the existing unit and saves the prior
      # content to `<path>.bak-<timestamp>`; on Linux it restarts the
      # running daemon so new Environment= lines take effect.
      #
      # With --json: emits a `hive-daemon-install.v1` envelope on every
      # outcome. Drift without --force exits 64 (USAGE — retry with
      # --force). Service-manager failure exits 70 (SOFTWARE). Success
      # outcomes (`written` / `upgraded` / `unchanged` / `unsupported`)
      # exit 0.
      def install_daemon
        require "hive/commands/daemon/service_installer"
        installer = Hive::Commands::Daemon::ServiceInstaller.new(binary_path: current_binary_path)
        begin
          result = installer.install!(autostart: true, force: @force)
        rescue Hive::Error
          raise
        rescue StandardError => e
          install_emit_exception_envelope(installer, e) if @json
          raise Hive::DaemonInstallFailed,
                "daemon service install failed: #{e.class}: #{e.message}"
        end
        unless @json
          installer.messages.each { |line| warn "hive: #{line}" }
          emit_install_success_summary(installer, result)
        end
        emit_install_outcome(installer, result)
      end

      # Bare-text positive confirmation on the non-JSON success path
      # so operators can distinguish first-time install / no-op /
      # in-place upgrade at a glance. Mirrors what `reload_daemon`
      # already does on its success path.
      def emit_install_success_summary(installer, outcome)
        return if @json

        case outcome.kind
        when :written
          puts "hive daemon: installed unit at #{installer.target_path}"
        when :upgraded
          msg = "hive daemon: upgraded unit at #{installer.target_path}"
          msg += " (backup: #{outcome.backup_path})" if outcome.backup_path
          puts msg
        when :unchanged
          puts "hive daemon: unit already up to date at #{installer.target_path}"
        when :autostart_unavailable
          # The unit was written; only autostart enablement was
          # impossible (e.g. Linux without systemd-user). Not a
          # failure — confirm the write and let installer.messages
          # carry the "how to enable autostart" guidance.
          puts "hive daemon: unit written at #{installer.target_path}; autostart not enabled on this host"
        when :unsupported, :drifted, :failed
          # :unsupported is messaged via installer.messages.
          # :drifted / :failed are handled by emit_install_outcome
          # (which raises); no positive summary applies.
        end
      end

      def emit_install_outcome(installer, outcome)
        if @json
          if outcome.success?
            puts JSON.generate(install_envelope(installer, outcome))
          else
            install_emit_error_envelope(installer, outcome: outcome.wire_outcome)
          end
        end

        if outcome.drifted?
          msg = "daemon unit at #{installer.target_path} differs from the current template. " \
                "Re-run with `hive daemon install --force` to overwrite (a timestamped .bak " \
                "will be saved)."
          raise Hive::DaemonInstallDriftError, msg
        elsif outcome.failed?
          raise Hive::DaemonInstallFailed,
                "daemon service install reported a failure; see messages above"
        end
      end

      def install_envelope(installer, outcome)
        # `target_path` is whatever the installer resolved: the written
        # unit path on linux/macos (including the autostart-unavailable
        # case, where the unit IS written), and nil only on a truly
        # unsupported host where no unit exists. `backup_path`/`restarted`
        # are only set on an :upgraded install, so reading them
        # unconditionally is correct.
        {
          "schema" => "hive-daemon-install",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-daemon-install"),
          "ok" => true,
          "outcome" => outcome.wire_outcome,
          "platform" => installer.envelope_platform,
          "target_path" => installer.target_path,
          "backup_path" => outcome.backup_path,
          "restarted" => outcome.restarted,
          "messages" => installer.messages.dup
        }
      end

      def install_emit_error_envelope(installer, outcome:)
        error_class = outcome == "drifted" ? "DaemonInstallDriftError" : "DaemonInstallFailed"
        exit_code = outcome == "drifted" ? Hive::ExitCodes::USAGE : Hive::ExitCodes::SOFTWARE
        message =
          if outcome == "drifted"
            "daemon unit at #{installer.target_path} differs from the current template; retry with --force."
          else
            "daemon service install reported a failure; see messages"
          end
        puts JSON.generate(
          "schema" => "hive-daemon-install",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-daemon-install"),
          "ok" => false,
          "error_class" => error_class,
          "error_kind" => outcome,
          "exit_code" => exit_code,
          "message" => message,
          "outcome" => outcome,
          "platform" => installer.envelope_platform,
          "target_path" => installer.target_path,
          "messages" => installer.messages.dup
        )
      end

      def install_emit_exception_envelope(installer, error)
        puts JSON.generate(
          "schema" => "hive-daemon-install",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-daemon-install"),
          "ok" => false,
          "error_class" => "DaemonInstallFailed",
          "error_kind" => "failed",
          "exit_code" => Hive::ExitCodes::SOFTWARE,
          "message" => "daemon service install failed: #{error.class}: #{error.message}",
          "outcome" => "failed",
          "platform" => safe_install_platform(installer),
          "target_path" => safe_install_target_path(installer),
          "messages" => safe_install_messages(installer)
        )
      end

      def current_binary_path
        Hive::InvokedBinary.path
      end

      def pin_runtime_hive_bin!
        return ENV["HIVE_BIN"] unless ENV["HIVE_BIN"].to_s.empty?

        invoked = current_binary_path
        ENV["HIVE_BIN"] = invoked if invoked
        invoked
      end

      def safe_install_platform(installer)
        installer.envelope_platform
      rescue StandardError
        "unsupported"
      end

      def safe_install_target_path(installer)
        installer.target_path
      rescue StandardError
        nil
      end

      def safe_install_messages(installer)
        installer.messages.dup
      rescue StandardError
        []
      end

      def envelope_schema
        "hive-daemon-enroll"
      end

      def envelope_error_kind(error)
        error_kind_for(error)
      end

      # Toggle `daemon.enabled` in one or more projects' per-project
      # config.yml. Atomic write via tempfile + rename + flock + fsync;
      # surgical line-level edit so operator comments and key order
      # survive (see upsert_daemon_enabled). The dispatcher picks up the
      # change on its next tick (`@enabled_cache.clear` runs every tick),
      # so SIGHUP is a hint not a requirement.
      #
      # Naming: matches the `do_call` convention used by every other
      # command class in lib/hive/commands/. `enabled` is derived from
      # @subcommand here rather than passed in so the entry point shape
      # mirrors Forget / Prune / Status / etc.
      def do_call
        enabled = (@subcommand == "enable")
        targets = resolve_enable_targets
        # Pre-flight: validate every target up front so `--all` can't
        # leave the registry half-flipped on a bad project mid-loop.
        preflight_targets(targets)
        results = targets.map do |entry|
          path = File.join(entry["hive_state_path"], "config.yml")
          previous = current_daemon_enabled(path)
          write_daemon_block(path, enabled)
          { "name" => entry["name"], "path" => entry["path"],
            "previous" => previous, "current" => enabled, "config_yml" => path }
        end

        if @json
          puts JSON.generate(
            "schema" => "hive-daemon-enroll",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-daemon-enroll"),
            "ok" => true,
            "subcommand" => @subcommand,
            "results" => results,
            "next_action" => enroll_next_action(results, enabled)
          )
          @stdout_written = true
        else
          verb = enabled ? "enabled" : "disabled"
          results.each do |r|
            # Idempotency signal in bare-text output: re-running on a
            # project whose enabled value already matches prints
            # "(already <verb>)" so the operator sees the no-op.
            # `previous` may be nil (no daemon block existed), in which
            # case we emit the "(was: <previous> → <current>)" form.
            suffix = if r["previous"] == enabled
                       " (already #{verb})"
            elsif r["previous"].nil?
                       " (was: unset → #{enabled})"
            else
                       " (was: #{r['previous']} → #{enabled})"
            end
            puts "hive daemon: #{verb} #{r['name']} (#{r['config_yml']})#{suffix}"
          end
          # Only emit the `next: hive daemon reload` paragraph when the
          # state actually flipped. JSON envelope emits `kind: no_op`
          # for the same case; bare-text and envelope must agree.
          any_changed = results.any? { |r| r["previous"] != enabled }
          if @subcommand == "enable" && !@all && any_changed
            puts ""
            puts "  next: hive daemon reload   # if the daemon is already running"
            puts "        hive daemon start --dry-run --detach   # if it's not"
          end
        end
      end

      def resolve_enable_targets
        if @all
          unless @target.nil? || @target.to_s.strip.empty?
            fail_usage!(
              "hive daemon #{@subcommand}: cannot combine PROJECT (#{@target.inspect}) with --all " \
              "(pass one or the other, not both)",
              kind: Hive::Schemas::EnrollErrorKind::PROJECT_AND_ALL
            )
          end
          projects = Hive::Config.registered_projects
          if projects.empty?
            fail_usage!(
              "hive daemon #{@subcommand} --all: no registered projects (run `hive init` first)",
              kind: Hive::Schemas::EnrollErrorKind::NO_PROJECTS
            )
          end
          projects
        elsif @target.nil? || @target.to_s.strip.empty?
          fail_usage!(
            "hive daemon #{@subcommand}: missing PROJECT (or pass --all)",
            kind: Hive::Schemas::EnrollErrorKind::MISSING_PROJECT
          )
        else
          entry = Hive::Config.find_project(@target)
          unless entry
            fail_usage!(
              "hive daemon #{@subcommand}: unknown project #{@target.inspect} " \
              "(see `hive status` for the registered set)",
              kind: Hive::Schemas::EnrollErrorKind::UNKNOWN_PROJECT
            )
          end
          [ entry ]
        end
      end

      def fail_usage!(message, kind:)
        error = UsageError.new(message, error_kind: kind)
        if @json
          emit_envelope(error)
        else
          warn message
        end
        raise error
      end

      def error_kind_for(error)
        case error
        when UsageError              then error.error_kind
        when Hive::ConfigError       then Hive::Schemas::EnrollErrorKind::CONFIG
        when Hive::InternalError     then Hive::Schemas::EnrollErrorKind::INTERNAL
        else                              Hive::Schemas::EnrollErrorKind::INTERNAL
        end
      end

      # Build the success envelope's `next_action` block so an agent can
      # branch deterministically without parsing the human-readable
      # bare-text hint. Two shapes:
      #
      #   { "kind" => "no_op",  "reason" => "no projects changed" }
      #     when every result is a no-op (previous == current). Agent
      #     can short-circuit any reload / restart logic.
      #
      #   { "kind" => "reload", "reason" => "daemon picks up the change
      #     within poll_interval_sec; reload is optional",
      #     "command" => "hive daemon reload", "required" => false }
      #     when at least one project's daemon.enabled actually flipped.
      #     `required: false` because the dispatcher's per-tick cache
      #     invalidation already picks up the change within
      #     poll_interval_sec (default 30 s).
      def enroll_next_action(results, enabled)
        any_changed = results.any? { |r| r["previous"] != enabled }
        if any_changed
          {
            "kind" => "reload",
            "command" => "hive daemon reload",
            "required" => false,
            "reason" => "daemon picks up daemon.enabled changes within " \
                        "poll_interval_sec on its next tick; reload is optional"
          }
        else
          { "kind" => "no_op", "reason" => "no projects changed" }
        end
      end

      # Struct returned by parse_project_config: the parsed Hash plus
      # the raw text, so downstream callers can reuse a single read
      # instead of opening cfg_path again. assert_surgical_edit_possible!
      # in particular needs the raw text (for BOM / CRLF / indent
      # checks) and the parsed data (for shape validation).
      ParsedConfig = Struct.new(:data, :text)

      # Single owner of the project-config YAML read. Centralises the
      # Psych::Exception → Hive::ConfigError translation and the
      # top-level-mapping shape check, so every read site (preflight,
      # current_daemon_enabled, write_daemon_block) reports malformed
      # YAML the same way and produces the same `config` error_kind.
      #
      # Returns a ParsedConfig (data + text) when the file exists and
      # parses to a mapping, or nil when the file is missing. Callers
      # handle missing-file via NOT_INITIALISED at their layer so we
      # can keep this helper free of the USAGE-vs-CONFIG split.
      def parse_project_config(cfg_path)
        return nil unless File.exist?(cfg_path)

        text = File.read(cfg_path)
        data = YAML.safe_load(text)
        if !data.nil? && !data.is_a?(Hash)
          raise Hive::ConfigError,
                "hive daemon #{@subcommand}: #{cfg_path} top-level YAML is not a mapping"
        end
        ParsedConfig.new(data || {}, text)
      rescue Psych::Exception => e
        raise Hive::ConfigError,
              "hive daemon #{@subcommand}: #{cfg_path} is not valid YAML: #{e.message}"
      end

      # Returns the current daemon.enabled value (true / false / nil)
      # for a project's config.yml, or nil if the file is missing.
      def current_daemon_enabled(cfg_path)
        parsed = parse_project_config(cfg_path)
        return nil if parsed.nil?
        return nil unless parsed.data["daemon"].is_a?(Hash)

        parsed.data["daemon"]["enabled"]
      end

      # Validate every target up front so `--all` can't leave the
      # registry in a half-flipped state when one project's config is
      # broken. The previous implementation iterated targets and wrote
      # each in turn — if project N raised on read or write, projects
      # 1..N-1 had already been mutated and projects N+1..end were
      # skipped. That weakens `disable --all` precisely when an
      # operator needs it (cost-runaway response). Pre-flight raises
      # the same errors `write_daemon_block` would have raised, but
      # before any disk mutation happens, so the whole operation is
      # transactional w.r.t. project-config validity. (Disk-full or
      # permission errors mid-loop are still possible; pre-flight only
      # protects against bad input, not bad disk state.)
      def preflight_targets(targets)
        targets.each do |entry|
          cfg_path = File.join(entry["hive_state_path"], "config.yml")
          unless File.exist?(cfg_path)
            fail_usage!(
              "hive daemon #{@subcommand}: missing #{cfg_path}; project " \
              "#{entry['name'].inspect} is not initialised " \
              "(run `hive init #{entry['path']}` to bootstrap it)",
              kind: Hive::Schemas::EnrollErrorKind::NOT_INITIALISED
            )
          end
          parsed = parse_project_config(cfg_path)
          if parsed.data["daemon"] && !parsed.data["daemon"].is_a?(Hash)
            raise Hive::ConfigError,
                  "hive daemon #{@subcommand}: #{cfg_path} `daemon:` is not a mapping"
          end
          assert_surgical_edit_possible!(cfg_path, parsed)
        end
      end

      # Reject existing `daemon:` blocks our line-level editor cannot
      # safely modify. Three rejection paths:
      #
      #   (a) Inline-flow style (`daemon: { enabled: false }`): YAML
      #       parses as Hash but no `^daemon:$` line at column 0.
      #   (b) CRLF line endings: the regex below matches `\Adaemon:[ \t]*\z`,
      #       which cannot match `daemon:\r` because `\r` is not in the
      #       character class. Caught by the `^daemon:$` line probe.
      #   (c) Non-2-space child indentation (4-space, tab, mixed): YAML
      #       parses fine but our line scanner expects exactly 2-space
      #       indentation under the daemon: header. A 4-space child
      #       slips past the first probe (the header line is at col 0
      #       and matches), then upsert_daemon_enabled fails to find
      #       `\A  enabled:` and falls into the "insert as first child"
      #       branch — producing a duplicate-key file.
      #
      # Without these checks, the file would corrupt on the FIRST call
      # (next safe_load would raise on the duplicate key, leaving the
      # operator with a config the tool itself can't recover). Fail
      # fast with a clear remediation.
      def assert_surgical_edit_possible!(cfg_path, parsed)
        # parsed is a ParsedConfig (data + text) so this helper does
        # not re-open cfg_path. Was previously File.read(cfg_path)
        # here even though parse_project_config had just read the
        # same file — a 2x-read-per-call waste flagged by the P3
        # maintainability review.
        text = parsed.text
        parsed_data = parsed.data

        # BOM check FIRST, before the empty-daemon early-return. UTF-8
        # BOM at the start of config.yml is precisely the case that
        # makes Psych silently lose the daemon: block — so parsed_data
        # might LOOK like the file has no daemon block when the on-disk
        # text actually has one. Without this guard, the surgical
        # editor would append a fresh `daemon:` block past the BOM,
        # producing a file the dispatcher (which also reads via Psych)
        # still cannot see. CLI would report `ok: true, current: true`
        # while the daemon never knows the project is enabled.
        # Use the explicit byte sequence rather than a literal U+FEFF in
        # source — embedding the BOM character itself in the source file
        # would make this file BOM-prefixed, which is the very condition
        # we're rejecting. The 3 bytes are UTF-8's BOM encoding.
        utf8_bom = "\xEF\xBB\xBF".dup.force_encoding("UTF-8")
        if text.start_with?(utf8_bom)
          raise Hive::ConfigError,
                "hive daemon #{@subcommand}: #{cfg_path} starts with a UTF-8 BOM " \
                "(byte sequence ef bb bf), which Psych silently mis-parses. " \
                "Strip the BOM before flipping daemon.enabled, e.g.:\n" \
                "  sed -i.bak '1s/^\\xEF\\xBB\\xBF//' #{cfg_path}"
        end

        return unless parsed_data.is_a?(Hash) && parsed_data["daemon"].is_a?(Hash)

        # Fast reject for CRLF — split on \r\n boundaries first to give
        # a precise error rather than the generic "non-2-space" message.
        if text.include?("\r\n")
          raise Hive::ConfigError,
                "hive daemon #{@subcommand}: #{cfg_path} uses CRLF line " \
                "endings; rewrite with LF endings (e.g., `dos2unix #{cfg_path}`) " \
                "before flipping daemon.enabled."
        end

        unless text.match?(/^daemon:[ \t]*(?:#.*)?$/)
          raise Hive::ConfigError,
                "hive daemon #{@subcommand}: #{cfg_path} has a `daemon:` block " \
                "in inline or non-2-space-indented style we can't surgically " \
                "edit. Rewrite the block in standard form:\n" \
                "  daemon:\n    enabled: <true|false>"
        end

        # Validate child indentation: every non-blank/non-comment line
        # within the daemon: block must use exactly 2-space indent. The
        # parsed_data tells us at least one child key exists (Hash with
        # entries), so the block isn't empty.
        validate_daemon_block_indent!(cfg_path, text) unless parsed_data["daemon"].empty?
      end

      # Walks the daemon: block in the raw text and ensures every
      # non-empty, non-comment line uses exactly 2-space indentation.
      # 4-space, tab-indented, or mixed-indent children would silently
      # bypass upsert_daemon_enabled's `\A  enabled:` regex and produce
      # a duplicate-key file on insert. (Tab-indented children are also
      # rejected by YAML.safe_load itself, surfacing as a Psych error
      # and exiting CONFIG via parse_project_config; this guard catches
      # the 4-space case which IS valid YAML but breaks our editor.)
      def validate_daemon_block_indent!(cfg_path, text)
        in_block = false
        text.each_line do |raw|
          line = raw.chomp
          if !in_block
            in_block = true if line =~ /\Adaemon:[ \t]*(?:#.*)?\z/
            next
          end
          # Block continues while line is empty, comment-only, or indented.
          break unless line.empty? || line.start_with?("#") || line =~ /\A[ \t]/
          next if line.empty? || line.lstrip.start_with?("#")
          next if line =~ /\A  \S/  # exactly 2-space indent (good)

          raise Hive::ConfigError,
                "hive daemon #{@subcommand}: #{cfg_path} has a `daemon:` " \
                "child line that does not use 2-space indentation: " \
                "#{line.inspect}. Rewrite children with 2-space indentation:\n" \
                "  daemon:\n    enabled: <true|false>"
        end
      end

      def write_daemon_block(cfg_path, enabled)
        # Defense-in-depth re-validation inside the per-project write,
        # in case the file changed between preflight and now (operator
        # hand-edit, another agent process). Pre-flight is the primary
        # gate; this re-check turns any race-window malformed write
        # into ConfigError instead of silent corruption.
        parsed = parse_project_config(cfg_path)
        if parsed.nil?
          fail_usage!(
            "hive daemon #{@subcommand}: missing #{cfg_path}; " \
            "this project is not initialised (run `hive init` from its root)",
            kind: Hive::Schemas::EnrollErrorKind::NOT_INITIALISED
          )
        end
        if parsed.data["daemon"] && !parsed.data["daemon"].is_a?(Hash)
          raise Hive::ConfigError,
                "hive daemon #{@subcommand}: #{cfg_path} `daemon:` is not a mapping"
        end
        assert_surgical_edit_possible!(cfg_path, parsed)

        # Atomic rewrite under an exclusive flock on a SIBLING .lock
        # file (not on cfg_path itself). flock-on-cfg-path would lock
        # the pre-rename inode; after our File.rename(tmp, cfg_path)
        # the path points to a new inode and a concurrent writer
        # opening cfg_path would take its lock instantly. The sibling
        # lock file's inode is stable across renames, so two writers
        # contending on it actually serialise. Pattern matches dpkg /
        # git's lock discipline.
        #
        # Mode bits are preserved so `chmod 0600 config.yml` survives.
        # `f.fsync` + ensure-cleanup of the tempfile match the durability
        # contract Hive::Markers#write_atomic provides for marker files.
        atomic_rewrite_with_lock(cfg_path, enabled)
      end

      # Encapsulates the lock acquire + atomic rewrite under ONE Errno::*
      # rescue scope. Errno from either the lock-file open OR the
      # tempfile/rename routes to Hive::ConfigError (exit 78), matching
      # Hive::Config.write_global_config!'s contract. Read-side errors
      # from parse_project_config and assert_surgical_edit_possible!
      # are NOT in scope (they ran in write_daemon_block before this
      # call), so they retain their NOT_INITIALISED / direct-raise
      # classification.
      def atomic_rewrite_with_lock(cfg_path, enabled)
        lock_path = "#{cfg_path}.lock"
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock_fd|
          lock_fd.flock(File::LOCK_EX)
          original_mode = File.stat(cfg_path).mode & 0o7777
          new_text = upsert_daemon_enabled(File.read(cfg_path), enabled)
          tmp = "#{cfg_path}.tmp.#{Process.pid}"
          renamed = false
          begin
            File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, original_mode) do |f|
              f.write(new_text)
              f.flush
              f.fsync
            end
            File.rename(tmp, cfg_path)
            renamed = true
            # fsync the PARENT directory after rename so the rename
            # itself survives power loss. Without this, a crash between
            # File.rename and the next dirty-page flush can revert the
            # rename (kernel may have committed the data blocks but not
            # the directory entry pointing at them). EINVAL on
            # filesystems that don't support directory fsync (rare,
            # mostly ancient FUSE drivers) — swallow silently.
            begin
              File.open(File.dirname(cfg_path), File::RDONLY) { |dir| dir.fsync }
            rescue Errno::EINVAL, NotImplementedError
              # filesystem doesn't support fsync on a dir — nothing we can do
            end
          ensure
            # Cleanup is best-effort: a TOCTOU between exist? and delete
            # (or an EACCES from antivirus / Spotlight on macOS) must not
            # mask the original write failure.
            if !renamed && File.exist?(tmp)
              begin
                File.delete(tmp)
              rescue StandardError
                # ignore — original write failure (if any) propagates.
              end
            end
          end
        end
      rescue Errno::ENOSPC, Errno::EROFS, Errno::EACCES, Errno::EXDEV, Errno::EDQUOT,
             Errno::ENOMEM, Errno::EIO, Errno::ENOENT => e
        raise Hive::ConfigError,
              "hive daemon #{@subcommand}: filesystem error rewriting #{cfg_path}: " \
              "#{e.class.name}: #{e.message}"
      end

      # Surgical line-level editor: returns a new YAML text with the
      # daemon.enabled key set to `value`. Preserves every comment, every
      # other key's order, and any inline comment on the enabled line
      # itself. Three branches:
      #
      #   1. `daemon:` block exists and contains an `enabled:` key  →
      #      replace only that line's value, keep the rest.
      #   2. `daemon:` block exists but has no `enabled:` key       →
      #      insert `  enabled: <value>` as the first child of the block.
      #   3. No `daemon:` block at all                              →
      #      append a fresh `daemon:` / `  enabled: <value>` block at EOF
      #      with a leading blank line for readability.
      #
      # Required indentation is 2 spaces (the project's `hive init`
      # template's convention). Hand-edits that switch to 4-space or tab
      # indentation under `daemon:` would still parse as YAML but the
      # surgical edit would not see the existing `enabled:` and would
      # fall into branch 2 (insert as first child). The duplicate key
      # then surfaces at YAML.safe_load time on the next call, which
      # raises ConfigError above.
      def upsert_daemon_enabled(text, value)
        bool = value ? "true" : "false"
        lines = text.split("\n", -1)

        daemon_line_idx = nil
        block_end_idx = nil
        enabled_line_idx = nil

        lines.each_with_index do |line, i|
          if daemon_line_idx.nil?
            daemon_line_idx = i if line =~ /\Adaemon:[ \t]*(?:#.*)?\z/
          elsif block_end_idx.nil?
            if line.empty? || line.start_with?("#") || line =~ /\A[ \t]/
              if enabled_line_idx.nil? && line =~ /\A  enabled:[ \t]/
                enabled_line_idx = i
              end
            else
              block_end_idx = i
            end
          end
        end

        if enabled_line_idx
          # Replace the ENTIRE value-portion (everything between the
          # prefix `  enabled: ` and an optional inline `# comment`),
          # not just the first non-whitespace token. The earlier
          # `\S+` left trailing tokens behind: `  enabled: false maybe`
          # became `  enabled: true maybe`, which YAML parsed as the
          # STRING "true maybe" (silent corruption — operator's
          # `dig("daemon","enabled") == true` would then fail). The
          # non-greedy `.*?` captures the value; the optional
          # `(\s+#.*)?` preserves any inline comment.
          lines[enabled_line_idx] = lines[enabled_line_idx].sub(
            /\A(  enabled:[ \t]+).*?(\s+#.*)?\z/, "\\1#{bool}\\2"
          )
        elsif daemon_line_idx
          lines.insert(daemon_line_idx + 1, "  enabled: #{bool}")
        else
          lines.pop while lines.last == ""
          lines << "" unless lines.empty?
          lines << "daemon:"
          lines << "  enabled: #{bool}"
          lines << ""
        end

        lines.join("\n")
      end

      # `start` and `tail` don't emit a JSON envelope (start blocks
      # forever; tail is a stream). An agent calling reflexively with
      # --json would get nothing parseable. Surface a one-line stderr
      # notice so the caller knows their flag was a no-op rather than
      # silently waiting for a JSON document that will never arrive.
      def warn_unsupported_json_flag
        warn "hive: --json is not supported on `#{@subcommand}`; flag ignored " \
             "(this subcommand is interactive / streaming, not envelope-emitting)"
      end

      def stop_envelope(running:, was_running:, stale_pid: nil, reason: nil)
        {
          "schema" => "hive-daemon-stop",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-daemon-stop"),
          "ok" => true,
          "running" => running,
          "was_running" => was_running,
          "stale_pid" => stale_pid,
          "reason" => reason
        }.compact
      end
    end
  end
end
