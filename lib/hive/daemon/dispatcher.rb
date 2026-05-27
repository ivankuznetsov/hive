require "digest"
require "hive/config"
require "hive/stages"
require "hive/task_action"
require "hive/daemon/policy"
require "hive/daemon/plan_approval"
require "hive/daemon/concurrency_controller"
require "hive/daemon/child_supervisor"
require "hive/daemon/status_consumer"
require "hive/daemon/stale_agent_healer"
require "hive/daemon/logger"
require "hive/update_check"
require "hive/update_check/state"
require "hive/install_channel"
require "hive/commands/update"

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
                     merge_watcher: nil, dry_run: false,
                     update_state: nil, update_checker: nil, channel_detector: nil)
        @config = config
        @controller = controller
        @supervisor = supervisor
        @status_consumer = status_consumer
        @logger = logger
        @merge_watcher = merge_watcher
        @dry_run = dry_run

        # Update-flow collaborators (plan 2026-05-27-002). The check runs
        # only when a state store is injected (the daemon does so); existing
        # tests that omit it get an inert dispatcher with no network access.
        @update_state = update_state
        @update_checker = update_checker || -> { Hive::UpdateCheck.latest }
        @channel_detector = channel_detector || -> { Hive::InstallChannel.detect }

        @daemon_cfg = config["daemon"] || {}
        @update_cfg = config["update"] || Hive::Config::DEFAULTS["update"]
        @update_check_enabled = @update_cfg.fetch("check", true)
        # NOTE: `update.auto` is intentionally NOT read here yet — bash
        # auto-update (U7) is the only consumer and is deferred, so every
        # channel is nudge-only. U7 will read it when it lands.
        @edit_debounce_sec = @daemon_cfg.fetch("edit_debounce_sec", 30)
        @shutdown_grace_sec = @daemon_cfg.fetch("shutdown_grace_sec", 600)
        @poll_interval_sec = @daemon_cfg.fetch("poll_interval_sec", 30)
        # Grace window for AGENT_WORKING markers with no PID attribute
        # (placeholders stamped on stage entry). Within this window the
        # dispatcher is presumed to be mid-spawn; past it, the marker
        # is healed to ERROR reason=agent_orphaned. Default is mirrored
        # from Hive::TaskAction::DEFAULT_AGENT_MARKER_GRACE_SEC so the
        # daemon and the synthetic-stale classification share one source
        # of truth — operator-overridable in the daemon config block.
        agent_marker_grace_sec = @daemon_cfg.fetch(
          "agent_marker_grace_sec",
          Hive::TaskAction::DEFAULT_AGENT_MARKER_GRACE_SEC
        )
        @stale_agent_healer = StaleAgentHealer.new(
          controller: @controller,
          logger: @logger,
          grace_sec: agent_marker_grace_sec
        )

        @shutdown = false
        @reload = false
        @reexec_requested = false
        # Baseline SHA-256 of the file that defines SCHEMA_VERSIONS. The
        # daemon is a long-running process whose in-memory constants
        # freeze at load time, while shelled-out `hive` subprocesses load
        # fresh code on every invocation. After a `git pull` or gem
        # upgrade that bumps a schema, the in-process consumer rejects
        # every envelope (e.g. 8946 `got 2, want 1` events were logged
        # over ~3 days between 2026-05-15 PR #78 and the next restart).
        # Capturing the source digest here lets `run_forever` detect the
        # drift and re-exec instead of hard-failing forever.
        @code_fingerprint = compute_code_fingerprint
        @last_reexec_at = nil
        @started_at = nil
        @last_tick_at = nil
        @dispatched_today = 0
        reset_active_agent_snapshot
        # Per-tick enable cache. Populated lazily within one tick so
        # each row-handler call does at most one `Config.load(project_root)`
        # per project, and cleared at the start of every tick so YAML
        # edits to `daemon.enabled` take effect within one poll
        # interval without the operator having to send SIGHUP.
        # PR-40 follow-up #2.
        @enabled_cache = {}
        # Per-tick set of project names whose layout is half-migrated
        # (non-empty legacy_stage_dirs). Populated at the start of each
        # tick from StatusConsumer::Result#projects; row dispatch refuses
        # any row whose project lives in this set. Issue #95.
        @legacy_layout_projects = {}
        # Process-lifetime set of project names we've already logged the
        # "legacy stage dirs detected" warning for, so a half-migrated
        # project doesn't spam daemon.log on every 30s poll. Cleared on
        # SIGHUP/reload — operator fixing the layout + reloading will
        # see the next warning the next time it goes red, but we don't
        # actively re-emit on every tick. Issue #95.
        @legacy_layout_logged = {}
      end

      # Single tick: reap, fetch, dispatch. Pure dispatcher — no signal
      # handling, no sleep. Public so tests can drive a single tick
      # deterministically.
      def tick(now: Time.now)
        @last_tick_at = now
        # PR-40 follow-up #2: clear the per-tick enable cache so a
        # `daemon.enabled` flip in `<project>/.hive-state/config.yml`
        # takes effect within one poll interval. Without this, the
        # cache populated on first sight stuck for the daemon's
        # lifetime and the only way to honour a disable was SIGHUP.
        @enabled_cache.clear
        @logger.event(:tick_begin, now: now.utc.iso8601)
        reset_active_agent_snapshot

        # 0. Throttled release check (independent of task status). Sets the
        # TUI-footer nudge state when behind; resilient — never crashes a tick.
        maybe_check_for_update(now: now)

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
        # Rebuild the per-tick set of half-migrated projects from the
        # status snapshot. Stays empty when the daemon talks to an old
        # status binary that didn't ship the field (Result#projects
        # defaults to []) so old binaries stay forward-compatible.
        # Issue #95.
        refresh_legacy_layout_projects(result.projects)
        refresh_active_agent_snapshot(result.rows)

        observe_external_running_rows(result.rows)

        # Heal AGENT_WORKING markers whose backing agent isn't alive
        # BEFORE per-row dispatch — a healed row classifies as :error on
        # the next status read, and we don't want the dispatcher to try
        # to advance the stage on the same tick that just learned the
        # agent died. The outer rescue protects the tick from a future
        # NoMethodError/TypeError in the healer: without it, a healer
        # bug would crash the tick before per-row dispatch and hit
        # StartLimitBurst=3 in the unit's restart-loop cap.
        begin
          @stale_agent_healer.heal(
            result.rows, now: now, legacy_layout_projects: @legacy_layout_projects
          )
        rescue StandardError => e
          @logger.event(:fatal,
                        message: "stale_agent_healer raised: #{e.class}: #{e.message}",
                        keeping_previous: true)
        end

        # 3. PrMergeWatcher tick (if present): check pending merges
        # first. Archive dispatches MUST flow through the same enable +
        # cap checks that advance dispatches use, so a project disabled
        # after enqueue can't sneak through and N concurrent merges
        # can't blow past the global / per-project caps.
        # PR-40 review P2 #4.
        @merge_watcher&.tick(now: now)&.each do |archive_dispatch|
          dispatch_archive_with_gates(archive_dispatch, now: now)
        end
        # Surface entries the watcher dropped after exhausting
        # GH_MAX_FAILURES so the operator sees the give-up signal in
        # daemon.log instead of the task silently sitting at
        # ready_to_archive forever (ce-code-review P1 #9).
        @merge_watcher&.last_tick_dropped&.each do |drop|
          @logger.event(:merge_watcher_dropped,
                        project: drop[:project], slug: drop[:slug],
                        pr_url: drop[:pr_url],
                        failure_count: drop[:failure_count],
                        last_error: drop[:last_error])
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
                                           dry_run: @dry_run, pid: Process.pid,
                                           code_fingerprint: @code_fingerprint)

        until @shutdown
          if version_drift_detected?
            new_fingerprint = compute_code_fingerprint
            @logger.event(:version_drift,
                          old_fingerprint: @code_fingerprint,
                          new_fingerprint: new_fingerprint,
                          pid: Process.pid)
            @reexec_requested = true
            @last_reexec_at = Time.now
            break
          end

          if @reload
            reload_config!
            @reload = false
          end
          tick
          interruptible_sleep(@poll_interval_sec)
        end

        @logger.event(:dispatcher_stopping, in_flight: @controller.in_flight_count,
                                            grace_sec: @shutdown_grace_sec,
                                            reexec_requested: @reexec_requested)
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

      def reexec_requested?
        @reexec_requested
      end

      private

      # Throttled (~daily) probe of the latest published release. On the
      # brew/AUR/bash channels it records a nudge (version + exact update
      # command) into the shared state file; the TUI footer renders it and
      # the bot pushes it once per version. Auto-update (bash channel, U7) is
      # deferred, so every channel is nudge-only for now. dev clones are
      # skipped. Resilient by contract: an offline/rate-limited/parse failure
      # degrades silently (R7/G4) and never raises out of a tick.
      #
      # `record_check!` runs BEFORE the probe on purpose: a failed probe still
      # consumes the daily throttle so an offline daemon can't hammer GitHub
      # (and trip the 60/hr anonymous rate limit) every tick. The cost is that
      # a transient blip defers the next attempt by ~a day — acceptable given
      # the daily cadence and nudge-only stakes.
      def maybe_check_for_update(now:)
        return unless @update_check_enabled
        return unless @update_state
        return unless @update_state.due?(now)

        @update_state.record_check!(now)
        result = @update_checker.call
        if result.nil?
          # Distinguish "checked, GitHub unreachable" from "checked, current"
          # so an operator debugging a missing nudge has a signal.
          @logger.event(:update_check_no_result)
          return
        end

        channel = @channel_detector.call
        if channel == "dev" || !result.behind?
          @update_state.clear_nudge!
          return
        end

        command = Hive::Commands::Update.nudge_command(channel)
        if command.nil?
          # An unrecognized channel has no canonical command; don't persist a
          # nudge with an empty command (it would render "update X.Y.Z: ").
          @logger.event(:update_nudge_no_command, channel: channel, latest: result.latest)
          return
        end

        @update_state.set_nudge(latest: result.latest, channel: channel, command: command)
        @logger.event(:update_available, current: result.current, latest: result.latest,
                                         channel: channel, command: command)
      rescue StandardError => e
        @logger.event(:update_check_error, error_class: e.class.name, message: e.message)
      end

      # SHA-256 of lib/hive.rb (the file holding SCHEMA_VERSIONS). Used
      # as a cheap drift signal — if the on-disk file's digest no longer
      # matches what we captured at startup, the loaded code is stale.
      # Returns nil on any failure; a nil baseline disables drift checks
      # so a transient read failure never re-execs.
      def compute_code_fingerprint
        path = Hive::Schemas.method(:schema_path).source_location.first
        Digest::SHA256.file(path).hexdigest
      rescue StandardError
        nil
      end

      # True iff a baseline fingerprint exists, a fresh fingerprint can
      # be computed, the two differ, and at least 60s have elapsed since
      # the last re-exec attempt. The rate-limit is a defense against a
      # pathological digest that flaps every tick.
      def version_drift_detected?
        return false if ENV["HIVE_DAEMON_NO_AUTO_REEXEC"] == "1"
        return false if @code_fingerprint.nil?
        return false if @last_reexec_at && (Time.now - @last_reexec_at) < 60

        current = compute_code_fingerprint
        return false if current.nil?

        current != @code_fingerprint
      end

      def reap_completed(now:)
        @supervisor.reap_all(now: now).each do |entry|
          @controller.record_completion(
            pid: entry.pid, exit_code: entry.exit_code, completed_at: now
          )
          # Refresh the recorded state-file mtime to its POST-completion
          # value. The agent likely wrote a fresh terminal/WAITING marker
          # which bumped the mtime; without this refresh, the next tick
          # would interpret the agent's own write as a user edit and
          # re-dispatch, flooding the agent. See PR-40 review P1 #1.
          refresh_post_completion_mtime(entry)

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

      # After a child exits, re-stat the task's state file and store
      # the result in the controller as the new "last observed" mtime.
      # The path was stashed on @running at dispatch time (passed
      # through from the status row) — PR-40 follow-up review C4.
      #
      # Stage-advancing runs (4-execute → 6-review) move the task
      # folder forward; the dispatched path no longer exists. We try
      # the at-dispatch path first (covers in-stage re-runs of
      # brainstorm/plan/review) and fall back to a slug-keyed search
      # of the project's stage directories so the controller's mtime
      # tracking still reflects the agent's most recent write at the
      # task's CURRENT location.
      def refresh_post_completion_mtime(child_entry)
        path = resolve_post_completion_path(child_entry)
        return unless path && File.exist?(path)

        @controller.observe_state_file_mtime(
          project: child_entry.project, slug: child_entry.slug,
          mtime: File.mtime(path)
        )
      rescue StandardError
        # Stat failure is non-fatal; just don't update.
      end

      # Resolution order:
      #   1. The path stashed at dispatch (status snapshot's state_file)
      #      — works when the task did NOT advance stage.
      #   2. A slug-keyed search of the project's stage directories —
      #      covers stage-advance runs where the source path is gone.
      def resolve_post_completion_path(child_entry)
        original = child_entry.state_file_path
        return original if original && File.exist?(original)

        project_entry = Hive::Config.find_project(child_entry.project)
        return original unless project_entry

        find_post_advance_state_file(project_entry["hive_state_path"], child_entry.slug) || original
      end

      def find_post_advance_state_file(hive_state_path, slug)
        return nil unless hive_state_path && Dir.exist?(hive_state_path)

        # Stage names from the SSOT — covers all seven directories,
        # so adding a new stage in modules/stages.rb auto-extends.
        Hive::Stages::DIRS.each do |stage_dir|
          slug_dir = File.join(hive_state_path, "stages", stage_dir, slug)
          next unless Dir.exist?(slug_dir)

          # The stage runner is the authoritative writer of the state
          # file's name; instead of hardcoding a stage→filename map
          # (which would silently drift on a rename), pick the most
          # recently modified .md in the slug folder.
          candidates = Dir[File.join(slug_dir, "*.md")]
          next if candidates.empty?

          return candidates.max_by { |f| File.mtime(f) }
        end
        nil
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
        return if @legacy_layout_projects.key?(row.project)

        decision = Policy.decide(
          action: row.action,
          stage: row.stage,
          command: row.suggested_command,
          state_file_mtime: row.state_file_mtime,
          last_dispatched_state_file_mtime:
            @controller.last_dispatched_state_file_mtime_for(project: row.project, slug: row.slug),
          now: now,
          edit_debounce_sec: @edit_debounce_sec
        )

        case decision
        when :dispatch
          # Pass through the reason the dispatch fired so the
          # `:dispatched` logger event can distinguish plan-approval
          # auto-advance from regular advance-action dispatches. An
          # agent or operator reading daemon.log can then audit WHICH
          # policy branch fired without re-implementing Policy.decide.
          trigger = Policy.plan_approval?(row.action, row.stage) ? "plan_approval" : "advance"
          dispatch_or_block(row, now: now, trigger: trigger)
        when :wait_for_debounce
          @logger.event(:debouncing, project: row.project, slug: row.slug,
                                     stage: row.stage, mtime: row.state_file_mtime&.utc&.iso8601)
        when :record_baseline
          # First-sight kind: edit row — seed the controller with the
          # current mtime so the next tick has something to compare
          # against. No dispatch on this tick; the next genuine user
          # edit (mtime > baseline) will trigger one. See PR-40 review
          # P1 #1.
          @controller.observe_state_file_mtime(
            project: row.project, slug: row.slug, mtime: row.state_file_mtime
          )
          @logger.event(:skipped, project: row.project, slug: row.slug,
                                  stage: row.stage, action: row.action,
                                  reason: "baseline_recorded")
        when :poll_for_merge
          enqueue_merge_watch(row)
        when :skip
          @logger.event(:skipped, project: row.project, slug: row.slug,
                                  stage: row.stage, action: row.action)
        end
      end

      def dispatch_or_block(row, now:, trigger: "advance")
        # The task folder may have vanished between status snapshot and
        # dispatch (concurrent `hive drop` or `hive forget`). A nil
        # folder is a separate signal — a malformed snapshot row —
        # so we surface a distinct reason instead of collapsing both
        # into the same log line.
        if row.folder.nil? || row.folder.to_s.empty?
          @logger.event(:skipped, project: row.project, slug: row.slug,
                                  stage: row.stage, action: row.action,
                                  reason: "folder_missing_nil")
          return
        end
        unless File.directory?(row.folder.to_s)
          @logger.event(:skipped, project: row.project, slug: row.slug,
                                  stage: row.stage, action: row.action,
                                  reason: "folder_missing")
          return
        end

        gate = @controller.can_dispatch?(
          project: row.project, slug: row.slug, now: now,
          external_global_count: @external_active_agent_total,
          external_project_count: external_active_agent_count_for(row.project)
        )
        unless gate == :ok
          @logger.event(:blocked, project: row.project, slug: row.slug,
                                  stage: row.stage, reason: gate.to_s)
          return
        end

        # Plan-approval rows need a command rewrite + marker flip BEFORE
        # dispatch because TaskAction emits `hive plan ...` for the
        # `plan_waiting` row state (correct for the manual TUI's `p`
        # re-run path) but the daemon wants `hive develop ...` to
        # advance the stage. The marker also has to flip `:waiting →
        # :complete` so the workflow verb's terminal-marker gate
        # (Hive::Commands::Approve::VALID_TERMINAL_MARKERS) accepts the
        # advance. Both steps live in Hive::Daemon::PlanApproval so the
        # daemon and the TUI's equivalent helper cannot drift.
        command = row.suggested_command
        if trigger == "plan_approval"
          begin
            command = PlanApproval.prepare(row.suggested_command, row.state_file)
          rescue PlanApproval::NotApprovable, ArgumentError => e
            @logger.event(:skipped, project: row.project, slug: row.slug,
                                    stage: row.stage, action: row.action,
                                    reason: "plan_approval_invalid: #{e.message}")
            return
          end
        end

        dispatch_command(
          command,
          project: row.project, slug: row.slug, stage: row.stage,
          state_file_mtime: row.state_file_mtime,
          state_file_path: row.state_file,
          hive_state_path: nil, # supervisor falls back to tmpdir
          now: now,
          trigger: trigger
        )
      end

      def observe_external_running_rows(rows)
        per_project = Hash.new(0)
        rows.each do |row|
          next unless externally_running?(row)
          next if @controller.running_task?(project: row.project, slug: row.slug)

          per_project[row.project] += 1
        end
        @controller.set_external_running_counts(per_project: per_project)
      end

      # PR-40 review P2 #4: archive dispatches must respect both
      # `daemon.enabled` (the project may have been disabled after the
      # PR-merge enqueue) and the concurrency caps (multiple PRs
      # merging at once would otherwise spawn N archives ignoring the
      # global / per-project ceiling).
      def dispatch_archive_with_gates(archive_dispatch, now:)
        project = archive_dispatch[:project]
        slug = archive_dispatch[:slug]

        unless project_enabled?(project)
          @logger.event(:skipped, project: project, slug: slug,
                                  stage: archive_dispatch[:stage],
                                  action: "archive",
                                  reason: "project_disabled_after_enqueue")
          return
        end

        # Mirror handle_row's @legacy_layout_projects guard: if the
        # project is mid-migration, the archive command's --from stage
        # may not match the current on-disk layout (the watcher's
        # ARCHIVE_VERB_TEMPLATE is frozen at class load). Skip the
        # dispatch and let handle_row re-enqueue once the half-migrated
        # state clears on a future tick. ce-code-review P1 #10.
        if @legacy_layout_projects.key?(project)
          @logger.event(:skipped, project: project, slug: slug,
                                  stage: archive_dispatch[:stage],
                                  action: "archive",
                                  reason: "legacy_layout_detected",
                                  note: "skipping archive while project layout is half-migrated; " \
                                        "next tick will re-enqueue once migration completes")
          return
        end

        gate = @controller.can_dispatch?(
          project: project, slug: slug, now: now,
          external_global_count: @external_active_agent_total,
          external_project_count: external_active_agent_count_for(project)
        )
        if gate == :ok
          dispatch_command(
            archive_dispatch[:command],
            project: project, slug: slug, stage: archive_dispatch[:stage],
            state_file_mtime: archive_dispatch[:state_file_mtime],
            state_file_path: nil, # archive doesn't track an mtime baseline
            hive_state_path: archive_dispatch[:hive_state_path],
            now: now
          )
        else
          # Archive will retry on the next tick if the gate clears.
          # The watcher already cleared this entry from its pending
          # set when it returned MERGED, so we need to re-enqueue so
          # the next tick attempts the dispatch again.
          @merge_watcher&.enqueue(
            project: project, slug: slug,
            task_folder: File.join(
              Hive::Config.find_project(project)["hive_state_path"],
              "stages", archive_dispatch[:stage], slug
            )
          ) if Hive::Config.find_project(project)
          @logger.event(:blocked, project: project, slug: slug,
                                  stage: archive_dispatch[:stage],
                                  action: "archive",
                                  reason: gate.to_s)
        end
      rescue StandardError => e
        # Defensive: re-enqueue path uses File.join + Config lookup
        # which can throw on edge cases. Don't let it crash the tick.
        @logger.event(:fatal, message: "archive dispatch error: #{e.class}: #{e.message}",
                              project: project, slug: slug)
      end

      def dispatch_command(command, project:, slug:, stage:, state_file_mtime:,
                           state_file_path:, hive_state_path:, now:, trigger: "advance")
        if @dry_run
          @logger.event(:dry_run, project: project, slug: slug, stage: stage,
                                  command: command)
        end
        pid = @supervisor.spawn(
          command_string: command,
          project: project, slug: slug, stage: stage,
          hive_state_path: hive_state_path,
          state_file_path: state_file_path,
          dry_run: @dry_run
        )
        @controller.record_dispatch(
          pid: pid, project: project, slug: slug, stage: stage,
          command: command, started_at: now, state_file_mtime: state_file_mtime
        )
        @logger.event(:dispatched, pid: pid, project: project, slug: slug,
                                   stage: stage, command: command, trigger: trigger,
                                   dry_run: @dry_run)
        @dispatched_today += 1
      end

      def enqueue_merge_watch(row)
        return unless @merge_watcher

        @merge_watcher.enqueue(project: row.project, slug: row.slug,
                               task_folder: row.folder)
        @logger.event(:merge_watcher_enqueued, project: row.project, slug: row.slug,
                                               folder: row.folder)
      end

      def reset_active_agent_snapshot
        @external_active_agent_total = 0
        @external_active_agent_counts = Hash.new(0)
      end

       # Populate the per-tick "skip this project's rows" set from the
       # status snapshot's projects[] list. A project counts as legacy if
       # its `legacy_stage_dirs` array is non-empty (i.e. tasks were left
       # in a pre-rename stage directory). Advancing a row on top of a
       # half-migrated layout would silently lose work, so we skip the
       # whole project until the operator runs `hive migrate`. Logging is
       # gated by `@legacy_layout_logged` so a half-migrated project
       # doesn't spam daemon.log every tick — first-sight only.
       # Issue #95.
       def refresh_legacy_layout_projects(projects)
         @legacy_layout_projects = {}
         Array(projects).each do |project|
           next unless project.respond_to?(:legacy?) && project.legacy?

           @legacy_layout_projects[project.name] = true
           next if @legacy_layout_logged[project.name]

           @logger.event(:legacy_layout_detected, project: project.name,
                                                  stage_dirs: project.legacy_stage_dirs.map { |d| d["stage_dir"] })
           @legacy_layout_logged[project.name] = true
         end
       end

       def refresh_active_agent_snapshot(rows)
        reset_active_agent_snapshot
        rows.each do |row|
          next unless active_agent_row?(row)
          next if @controller.running_task?(project: row.project, slug: row.slug)

          @external_active_agent_total += 1
          @external_active_agent_counts[row.project] += 1
        end
      end

      def active_agent_row?(row)
        externally_running?(row)
      end

      # A row counts as externally running when `Hive::TaskAction` has
      # classified it as `agent_running` AND we have positive evidence
      # that the run is in flight — either the .lock recorded a live
      # claude_pid, OR `Hive::Commands::Status` verified the .lock
      # holder PID + process_start_time still match (`live_task_lock`).
      # Both the dispatcher's global concurrency counter
      # (`@external_active_agent_total`) and the controller's per-project
      # counter (`set_external_running_counts`) use this predicate so
      # they agree on which rows count against the cap. Issue #144
      # narrowed the predicate from "claude_pid_alive != false" (which
      # over-counted rows with no liveness signal) and broadened the
      # strict "claude_pid_alive == true" path (which silently dropped
      # live_task_lock-only rows during the pre-claude window).
      def externally_running?(row)
        return false unless row.action == Hive::Schemas::TaskActionKind::AGENT_RUNNING

        row.claude_pid_alive == true || row.live_task_lock == true
      end

      def external_active_agent_count_for(project)
        @external_active_agent_counts.fetch(project, 0)
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
        # PR-40 review P1 #2: rebase on the global ~/Dev/hive/config.yml's
        # daemon block, not bare DEFAULTS.
        @daemon_cfg = Hive::Config.load_global_daemon
        @update_cfg = Hive::Config.load_global_update
        @config = { "daemon" => @daemon_cfg, "update" => @update_cfg }
        @update_check_enabled = @update_cfg.fetch("check", true)
        @edit_debounce_sec = @daemon_cfg.fetch("edit_debounce_sec", 30)
        @shutdown_grace_sec = @daemon_cfg.fetch("shutdown_grace_sec", 600)
        @poll_interval_sec = @daemon_cfg.fetch("poll_interval_sec", 30)
        # Rebuild the healer so an operator tuning
        # daemon.agent_marker_grace_sec via SIGHUP takes effect within
        # one tick. Without this rebuild the healer keeps the grace it
        # captured at boot and only a full daemon restart applies new
        # values.
        @stale_agent_healer = StaleAgentHealer.new(
          controller: @controller,
          logger: @logger,
          grace_sec: @daemon_cfg.fetch(
            "agent_marker_grace_sec",
            Hive::TaskAction::DEFAULT_AGENT_MARKER_GRACE_SEC
          )
        )
        @enabled_cache.clear
        @logger.event(:config_reloaded)
      rescue Hive::ConfigError => e
        # If the operator broke the config mid-run, log and keep
        # running on the old values rather than crashing.
        @logger.event(:fatal, message: "config reload failed: #{e.message}",
                              keeping_previous: true)
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
