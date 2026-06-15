require "digest"
require "fileutils"
require "shellwords"
require "hive/config"
require "hive/stages"
require "hive/task_action"
require "hive/brainstorm_parser"
require "hive/daemon/policy"
require "hive/daemon/plan_approval"
require "hive/daemon/concurrency_controller"
require "hive/daemon/child_supervisor"
require "hive/daemon/status_consumer"
require "hive/daemon/stale_agent_healer"
require "hive/daemon/display_name_backfiller"
require "hive/daemon/dispatch_request_queue"
require "hive/daemon/dispatch_result_queue"
require "hive/daemon/logger"
require "hive/daemon/digest_scheduler"
require "hive/daemon/patrol_scheduler"
require "hive/daemon/pr_merge_watcher"
require "hive/lock"
require "hive/paths"
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
    # Each `tick` is one full round: reap completed children, fetch status,
    # decide per row, dispatch where allowed. The poller also wakes at
    # `daemon.fast_poll_sec` cadence for cheap child-reap/state-file-mtime
    # probes; a full tick still runs at `daemon.poll_interval_sec` as the
    # backstop. Signals (TERM/INT/HUP) drive graceful shutdown / config reload.
    class Dispatcher
      attr_reader :controller, :supervisor, :logger

      # Stage dir whose `needs_input` rows carry a brainstorm Q&A file the
      # daemon gates auto-resume on (see `brainstorm_answers_pending?`).
      BRAINSTORM_STAGE_DIR = "2-brainstorm".freeze

      # @param config [Hash] merged config (Hive::Config.load) — used for
      #   the `daemon` block defaults; per-project enrollment is read from
      #   each project's own config via Hive::Config.load(project_root).
      # @param controller [ConcurrencyController]
      # @param supervisor [ChildSupervisor]
      # @param status_consumer [StatusConsumer]
      # @param logger [Hive::Daemon::Logger]
      # @param merge_watcher [PrMergeWatcher, nil]
      # @param patrol_scheduler [PatrolScheduler, nil]
      # @param dry_run [Boolean]
      def initialize(config:, controller:, supervisor:, status_consumer:, logger:,
                     merge_watcher: nil, patrol_scheduler: nil, digest_scheduler: nil, dry_run: false,
                     update_state: nil, update_checker: nil, channel_detector: nil,
                     dispatch_request_state_home: nil, dispatch_result_state_home: nil)
        @config = config
        @controller = controller
        @supervisor = supervisor
        @status_consumer = status_consumer
        @logger = logger
        @merge_watcher = merge_watcher
        @patrol_scheduler = patrol_scheduler
        @digest_scheduler = digest_scheduler
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
        @fast_poll_sec = @daemon_cfg.fetch("fast_poll_sec", 1)
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
        # Additive self-heal for tasks whose one-shot name generation at
        # `hive new` never landed (agent/codex outage). Re-spawns
        # `hive generate-name <folder>` on later ticks; never touches
        # markers or dispatch.
        @display_name_backfiller = DisplayNameBackfiller.new(
          logger: @logger,
          dry_run: @dry_run
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
        @tracked_state_file_mtimes = {}
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
        # Test-injectable state homes for the dispatch-request and
        # dispatch-result queues. Production passes nil so both resolve
        # `Hive::Paths.state_home`; unit tests inject a sandbox. The result
        # home is separately injectable so a test sandboxing the request
        # queue doesn't silently write result notices where the bot (which
        # resolves the result home independently) never reads them (#251).
        @dispatch_request_state_home = dispatch_request_state_home
        @dispatch_result_state_home = dispatch_result_state_home
        # `[project, slug] → last-logged error signature` for the
        # brainstorm-gate parse-error log dedup (see
        # `brainstorm_answers_pending?`).
        @brainstorm_parse_errors = {}
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

        # 1c. Enforce per-child wall-clock timeouts (R-02). A wedged
        # `hive run` would otherwise hold a concurrency slot until daemon
        # shutdown; this SIGTERMs (then SIGKILLs after a grace) any
        # over-deadline child and logs the action. The killed child
        # surfaces as a normal ChildExit on a later reap, which then
        # frees the slot via the controller.
        enforce_child_timeouts(now: now)

        # 1d. Bound the dispatch-result notice dir (ADV-1 #6).
        prune_dispatch_results(now: now)

        # 1e. Global daily shipped digest. This is not project-scoped and
        # does not depend on the status snapshot, so it runs before status
        # fetch and bypasses per-project daemon gates. Wrapped like the
        # sibling self-heal ops below: `tick` does disk I/O (first-run seed
        # + catch-up-cap `write_state`), and an unguarded SystemCallError
        # (ENOSPC/EROFS/EACCES) would otherwise crash the whole tick and
        # trip the unit's restart-loop cap.
        begin
          @digest_scheduler&.tick(now: now)&.each do |digest_dispatch|
            dispatch_digest(digest_dispatch, now: now)
          end
        rescue StandardError => e
          @logger.event(:fatal,
                        message: "digest_scheduler.tick raised: #{e.class}: #{e.message}",
                        keeping_previous: true)
        end

        # 2. Fetch status
        result = @status_consumer.fetch
        unless result.ok
          @logger.event(:status_failure, error: result.error)
          @logger.event(:tick_end, now: Time.now.utc.iso8601, action: "status_failure")
          return
        end
        # Forward schema-version skew (tolerated, parsed best-effort): an
        # updated `hive` binary emitted a newer hive-status envelope than
        # this long-running daemon was built for. Log once; the tick
        # proceeds on the additive payload. Restart picks up the schema.
        @logger.event(:status_schema_skew, message: result.warning) if result.warning
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

        # Self-heal tasks left showing their raw slug because name
        # generation never landed at `hive new`. Purely additive and
        # marker-free, so order relative to dispatch is irrelevant — but
        # it shares the healer's defensive rescue so a backfiller bug
        # can't crash the tick (and trip the unit's restart-loop cap).
        begin
          @display_name_backfiller.backfill(result.rows, now: now)
        rescue StandardError => e
          @logger.event(:fatal,
                        message: "display_name_backfiller raised: #{e.class}: #{e.message}",
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

        # 3b. Dispatch-request queue (plan 2026-05-28-002). Process
        # bot-written request files BEFORE the per-row scan so a slug
        # whose request just spawned is already in-flight in the
        # controller and the row scan's gate keeps the status-row loop
        # from double-dispatching. Single-writer invariant: only the
        # daemon spawns `hive run`-class verbs.
        process_dispatch_requests(now: now)

        # 3c. Project-level patrol scans are not task rows, so they do
        # not go through Policy. They still pass through the same
        # daemon.enabled, legacy-layout, dry-run, and concurrency gates
        # before any subprocess is spawned.
        @patrol_scheduler&.tick(now: now)&.each do |patrol_dispatch|
          dispatch_patrol_with_gates(patrol_dispatch, now: now)
        end

        # 4. Per-row dispatch, later pipeline stages first (see
        # dispatch_priority_order) so work nearest completion drains
        # ahead of newer earlier-stage work when slots are scarce.
        dispatch_priority_order(result.rows).each { |row| handle_row(row, now: now) }

        # 5. Bound the persisted dispatch-baseline file to the live task set.
        # Only reached on a SUCCESSFUL status fetch (the `unless result.ok`
        # early return above guards a transient empty/failed scan from wiping
        # baselines). `scope_projects` is the further per-project guard:
        # `StatusConsumer` filters out projects with `error: not_initialised`
        # / `missing_project_path` from BOTH `rows` and `projects`, so passing
        # `result.projects` as the scope means a per-project hiccup keeps its
        # baselines untouched until that project reappears cleanly (without
        # this, every transient project-level error would silently re-strand
        # every answered needs_input row in that project on the next tick).
        @controller.prune_dispatch_baselines(
          result.rows.map { |row| [ row.project, row.slug ] },
          scope_projects: Array(result.projects).map(&:name)
        )
        refresh_tracked_state_file_mtimes(result.rows)

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

        # C3: clean up dispatch-request claims left by a prior process
        # before the first tick, so a crash-restart neither re-dispatches
        # an already-run request nor leaks claim files for dead owners.
        recover_dispatch_claims(now: Time.now)

        until @shutdown
          now = Time.now
          full_tick = full_tick_due?(now)

          # Schema-drift detection hashes the schema file (Digest::SHA256.file),
          # so it is full-tick-only work. Running it every fast_poll_sec (~1s)
          # would execute the hash ~30x more often on the idle path and fight
          # the near-zero idle-CPU goal (Unit 2: the per-second probe is meant
          # to be cheap waitpid + stat only). The drift it guards against only
          # matters at the poll-interval (~30s) cadence.
          if full_tick && version_drift_detected?
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
          if full_tick
            tick(now: now)
          elsif cheap_probe_requires_full_tick?(now: now)
            tick(now: Time.now) unless @shutdown || @reload
          end
          interruptible_sleep(@fast_poll_sec)
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
        ::Digest::SHA256.file(path).hexdigest
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

      # R-02: drive the supervisor's per-child timeout enforcement and
      # log one `:child_timeout` event per signal sent. Wrapped so a kill
      # error never crashes a tick. (Every supervisor — real and test —
      # implements `enforce_timeouts`; the old `respond_to?` seam was
      # removed in #252.)
      def enforce_child_timeouts(now:)
        @supervisor.enforce_timeouts(now: now).each do |action|
          @logger.event(:child_timeout,
                        pid: action.pid, project: action.project,
                        slug: action.slug, stage: action.stage,
                        action: action.action.to_s,
                        elapsed_sec: action.elapsed_sec,
                        timeout_sec: action.timeout_sec,
                        command: action.command)
        end
      rescue StandardError => e
        @logger.event(:fatal,
                      message: "enforce_child_timeouts raised: #{e.class}: #{e.message}",
                      keeping_previous: true)
      end

      def full_tick_due?(now)
        @last_tick_at.nil? || (now - @last_tick_at) >= @poll_interval_sec
      end

      def cheap_probe_requires_full_tick?(now:)
        # When this returns true via `child_exited`, the follow-up `tick`
        # calls `reap_completed` again. That second sweep is a benign
        # waitpid no-op: the children were already reaped (and their
        # completions recorded) here, so `reap_all` finds nothing and
        # `record_completion` does not re-fire. The redundancy is
        # intentional — the probe must reap to *learn* whether a full
        # tick is warranted — not a missed dedup.
        #
        # Asymmetry: this probe only reaps real children via
        # `reap_completed`; `reap_dry_run` runs solely inside the full
        # `tick`. So dry-run pseudo-child completions are not accelerated
        # by the fast probe and advance only on the `@poll_interval_sec`
        # backstop. Harmless — dry-run is not the latency path the AC
        # targets — but noted to prevent future confusion.
        child_exited = reap_completed(now: now)
        state_file_changed = tracked_state_file_mtime_changed?
        child_exited || state_file_changed
      end

      def reap_completed(now:)
        entries = @supervisor.reap_all(now: now)
        entries.each do |entry|
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
          # Request-driven runs (bot-issued, daemon-spawned) remove their
          # queue file on reap so the daemon never re-dispatches them and
          # an operator tailing daemon.log sees the full lifecycle:
          # observed → dispatched → completed. The bot side is now a
          # producer only; the daemon is the single dispatcher.
          # ChildExit always defines `request_id` (nilable on the
          # Struct), so `respond_to?` is dead code per M-02 from
          # PR #241 ce-code-review. Just check the value.
          if entry.request_id
            # ADV-1: read routing metadata BEFORE remove() unlinks the file,
            # so the completion can be surfaced back to the originating chat.
            meta = Hive::Daemon::DispatchRequestQueue.metadata(
              entry.request_id, state_home: dispatch_request_state_home
            )
            continuation = promote_dispatch_sequence(entry, meta, now: now) if entry.exit_code == 0
            Hive::Daemon::DispatchRequestQueue.discard_sequence(
              entry.request_id, state_home: dispatch_request_state_home
            ) unless entry.exit_code == 0
            Hive::Daemon::DispatchRequestQueue.remove(
              entry.request_id, state_home: dispatch_request_state_home
            )
            @logger.event(:dispatch_request_completed,
                          request_id: entry.request_id, pid: entry.pid,
                          project: entry.project, slug: entry.slug,
                          exit_code: entry.exit_code,
                          elapsed_sec: (now - entry.started_at).to_i,
                          envelope_marker: entry.json_envelope&.dig("marker"),
                          envelope_ok: entry.json_envelope&.dig("ok"))
            notify_dispatch_result(entry, meta, now: now) unless continuation
          end
          # The global digest is a pseudo-project ("digest"), not a real
          # registry entry. A digest ConfigError (exit 78) is handled by the
          # scheduler's own backoff (below); dropping a phantom "digest"
          # project would emit a misleading :project_dropped event and leave
          # a permanent phantom entry the digest gate never consults.
          if entry.exit_code == Hive::ExitCodes::CONFIG &&
             entry.stage != Hive::Daemon::DigestScheduler::DIGEST_STAGE
            @controller.record_project_dropped(project: entry.project)
            @logger.event(:project_dropped, project: entry.project)
          end
          if entry.stage == Hive::Daemon::PatrolScheduler::PATROL_STAGE
            @patrol_scheduler&.complete(project: entry.project, exit_code: entry.exit_code, now: now)
          end
          if entry.stage == Hive::Daemon::DigestScheduler::DIGEST_STAGE
            # `complete` advances the cursor via `write_state`; isolate its
            # disk I/O so an ENOSPC/EROFS fault on the digest can't crash the
            # reap (and with it the whole poll loop).
            begin
              @digest_scheduler&.complete(date: entry.slug, exit_code: entry.exit_code, now: now)
            rescue StandardError => e
              @logger.event(:fatal,
                            message: "digest_scheduler.complete raised: #{e.class}: #{e.message}",
                            keeping_previous: true)
            end
          end
        end
        entries.any?
      end

      # Snapshot each tracked state file's on-disk mtime so the next fast
      # probe can detect a write. Store the raw `safe_mtime` (which is nil
      # when the file is absent) rather than falling back to the status
      # row's mtime: `tracked_state_file_mtime_changed?` re-stats with the
      # same `safe_mtime`, so a `nil` baseline compares stable against a
      # `nil` re-stat. Falling back to `row.state_file_mtime` (a Time) for
      # an absent file made every probe see `Time != nil` and fire a full
      # tick every second until a full tick re-baselined.
      #
      # NOTE: these mtimes are captured POST-dispatch, so a slug freshly
      # spawned this tick has its pre-dispatch mtime recorded here. When
      # the spawned agent writes its AGENT_WORKING marker (~1s later) the
      # next probe sees the bump and forces one redundant full tick. That
      # re-evaluation is correct (the marker really did change) and
      # low-frequency, so it's left as-is rather than special-cased.
      def refresh_tracked_state_file_mtimes(rows)
        @tracked_state_file_mtimes = {}
        rows.each do |row|
          next if row.state_file.nil? || row.state_file.empty?

          @tracked_state_file_mtimes[row.state_file] = safe_mtime(row.state_file)
        end
      end

      def tracked_state_file_mtime_changed?
        @tracked_state_file_mtimes.any? do |path, previous_mtime|
          current_mtime = safe_mtime(path)
          current_mtime != previous_mtime
        end
      end

      def safe_mtime(path)
        File.mtime(path) if path && File.exist?(path)
      rescue StandardError
        nil
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
          # Mirror reap_completed's digest hook: a dry-run digest pseudo-child
          # must also clear the scheduler's `@pending` marker, or `tick`
          # returns [] forever (`@pending.any?`) and the dry-run daemon wedges
          # after dispatching the digest exactly once. Isolate the disk I/O the
          # same way the sibling branch does.
          if entry.stage == Hive::Daemon::DigestScheduler::DIGEST_STAGE
            begin
              @digest_scheduler&.complete(date: entry.slug, exit_code: entry.exit_code, now: now)
            rescue StandardError => e
              @logger.event(:fatal,
                            message: "digest_scheduler.complete raised: #{e.class}: #{e.message}",
                            keeping_previous: true)
            end
          end
          @logger.event(:child_exited,
                        pid: entry.pid, exit_code: entry.exit_code,
                        project: entry.project, slug: entry.slug, stage: entry.stage,
                        dry_run: true, elapsed_sec: 0)
        end
      end

      def handle_row(row, now:)
        return unless project_enabled?(row.project)
        return if @legacy_layout_projects.key?(row.project)
        if merged_pr_recoverable_finalize_error?(row)
          enqueue_merge_watch(row, error_reason: row.marker_attrs.to_h["reason"].to_s)
          return
        end

        decision = Policy.decide(
          action: row.action,
          stage: row.stage,
          command: row.suggested_command,
          state_file_mtime: row.state_file_mtime,
          last_dispatched_state_file_mtime:
            @controller.last_dispatched_state_file_mtime_for(project: row.project, slug: row.slug),
          now: now,
          edit_debounce_sec: @edit_debounce_sec,
          answers_pending: brainstorm_answers_pending?(row)
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
        when :wait_for_answers
          # Brainstorm Q&A still has unanswered questions. Each Telegram
          # answer bumps the file mtime, so without this gate the daemon
          # would resume mid-session (with partial answers) and grab the
          # task lock, bouncing the operator's next answer.
          @logger.event(:skipped, project: row.project, slug: row.slug,
                                  stage: row.stage, action: row.action,
                                  reason: "answers_pending")
        when :poll_for_merge
          enqueue_merge_watch(row)
        when :skip
          @logger.event(:skipped, project: row.project, slug: row.slug,
                                  stage: row.stage, action: row.action)
        end
      end

      # True when `row` is a brainstorm `needs_input` row whose
      # `brainstorm.md` still has UNANSWERED questions. Only brainstorm
      # rows carry Q&A markers, so every other edit-resume row (execute /
      # review WAITING) returns false and behaves exactly as before. The
      # daemon parses the file directly (the published hive-status schema
      # carries no question count) via the shared `Hive::BrainstormParser`.
      #
      # Fails OPEN (returns false → resume allowed) when the file parses
      # to ZERO questions or on an unexpected error. This is deliberate
      # and self-healing, NOT a gap: the Telegram bot locates questions
      # with the SAME parser, so a file with no parseable `### Q{n}.`
      # (empty, agent crashed mid-write, or header drift) is one the
      # operator cannot answer via the bot either — the only way forward
      # is to re-run the brainstorm agent, which regenerates a clean file.
      # Holding instead would strand the task. The gate's job is narrow:
      # block the resume only while there are questions the operator is
      # actively answering.
      def brainstorm_answers_pending?(row)
        return false unless row.action == Hive::Schemas::TaskActionKind::NEEDS_INPUT
        return false unless row.stage == BRAINSTORM_STAGE_DIR

        path = row.state_file
        return false unless path && File.exist?(path)

        parsed = Hive::BrainstormParser.parse(path)
        pending = Hive::BrainstormParser.unanswered_questions(parsed).any?
        @brainstorm_parse_errors.delete([ row.project, row.slug ])
        pending
      rescue StandardError => e
        # `parse` is total (scrubs encoding, swallows IO), so this is a
        # belt-and-suspenders guard. Dedup the log per (project, slug) so
        # a persistently unreadable file can't emit `:fatal` on every
        # ~30s tick forever — only on first sight and on change.
        log_brainstorm_parse_error(row, e)
        false
      end

      def log_brainstorm_parse_error(row, error)
        key = [ row.project, row.slug ]
        signature = "#{error.class}: #{error.message}"
        return if @brainstorm_parse_errors[key] == signature

        @brainstorm_parse_errors[key] = signature
        @logger.event(:fatal,
                      message: "brainstorm_answers_pending? raised: #{signature}",
                      project: row.project, slug: row.slug, keeping_previous: true)
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

        # Per-slug in-flight gate — prevents the row scan from
        # double-dispatching a slug the dispatch-request queue just
        # spawned earlier in this same tick. The status snapshot was
        # taken BEFORE process_dispatch_requests, so a needs_input
        # row that just had its request fired would otherwise hit
        # handle_row → dispatch_or_block with no signal of the in-
        # flight child. The controller's `running_task?` predicate
        # reflects `record_dispatch` calls, so the gate is naturally
        # correct across tick-internal ordering.
        if @controller.running_task?(project: row.project, slug: row.slug)
          @logger.event(:blocked, project: row.project, slug: row.slug,
                                  stage: row.stage, reason: "in_flight")
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

      # Order rows so tasks closer to the end of the pipeline dispatch
      # first: a 7-artifacts row before a 6-review row, an 8-finalize
      # before both. When concurrency slots are scarce this drains work
      # nearest completion ahead of newer earlier-stage work (a WIP-limit
      # — don't start a fresh review while finalizes wait on a slot).
      # Stable within a stage (original status order preserved), and
      # unranked/unknown stages sort last.
      def dispatch_priority_order(rows)
        rows.each_with_index
            .sort_by { |row, idx| [ -stage_rank(row.stage), idx ] }
            .map(&:first)
      end

      # Pipeline position of a stage dir (higher = closer to done); -1 for
      # an unrecognized stage so it deprioritizes behind every known stage.
      def stage_rank(stage)
        Hive::Stages::DIRS.index(stage.to_s) || -1
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
            ),
            error_reason: archive_dispatch[:error_reason]
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

      def dispatch_patrol_with_gates(patrol_dispatch, now:)
        project = patrol_dispatch[:project]
        slug = patrol_dispatch[:slug] || Hive::Daemon::PatrolScheduler::PATROL_SLUG

        # Every gated early-return below MUST release the scheduler's
        # pending marker. The scheduler set `@pending[project]` in `tick`
        # before producing this dispatch, and only `complete` (called on
        # child reap) clears it. A gated patrol never spawns a child, so
        # without `cancel` the project would stay pending forever and
        # never be patrolled again until the daemon restarts.
        unless project_enabled?(project)
          @logger.event(:skipped, project: project, slug: slug,
                                  stage: patrol_dispatch[:stage],
                                  action: "patrol",
                                  reason: "project_disabled")
          @patrol_scheduler&.cancel(project: project)
          return
        end

        if @legacy_layout_projects.key?(project)
          @logger.event(:skipped, project: project, slug: slug,
                                  stage: patrol_dispatch[:stage],
                                  action: "patrol",
                                  reason: "legacy_layout_detected")
          @patrol_scheduler&.cancel(project: project)
          return
        end

        # Patrol scans use their OWN concurrency budget (not the task
        # max_concurrent_runs) so a long codex-backed scan never starves
        # task dispatch — a running scan no longer eats a task slot.
        gate = @controller.can_dispatch_patrol_scan?(project: project, now: now)
        unless gate == :ok
          @logger.event(:blocked, project: project, slug: slug,
                                  stage: patrol_dispatch[:stage],
                                  action: "patrol",
                                  reason: gate.to_s)
          @patrol_scheduler&.cancel(project: project)
          return
        end

        dispatch_command(
          patrol_dispatch[:command],
          project: project, slug: slug, stage: patrol_dispatch[:stage],
          state_file_mtime: patrol_dispatch[:state_file_mtime],
          state_file_path: patrol_dispatch[:state_file_path],
          hive_state_path: patrol_dispatch[:hive_state_path],
          now: now,
          trigger: "patrol",
          kind: :patrol_scan
        )
      rescue StandardError => e
        # A spawn error is a genuine failure: route it through `complete`
        # with a non-zero exit so the project both clears its pending
        # marker AND accrues the failure backoff before being retried.
        @patrol_scheduler&.complete(project: project, exit_code: 1, now: now)
        @logger.event(:fatal, message: "patrol dispatch error: #{e.class}: #{e.message}",
                              project: project, slug: slug)
      end

      def dispatch_digest(digest_dispatch, now:)
        date = digest_dispatch[:slug]
        project = digest_dispatch[:project]

        # Gate the global digest through the controller so it (a) never
        # holds a task slot or pushes the daemon past max_concurrent_runs,
        # and (b) can't double-dispatch the same date while a prior digest
        # child is still tracked — e.g. a restart that lost the scheduler's
        # in-memory pending marker. Tagged `kind: :digest`, off the task
        # caps. A gated dispatch releases the scheduler's pending marker so
        # the next eligible tick re-evaluates it.
        gate = digest_dispatch_gate(project: project, date: date, now: now)
        unless gate == :ok
          @logger.event(:blocked, project: project, slug: date,
                                  stage: digest_dispatch[:stage],
                                  action: "digest", reason: gate.to_s)
          @digest_scheduler&.cancel(date: date)
          return
        end

        dispatch_command(
          digest_dispatch[:command],
          project: project,
          slug: date,
          stage: digest_dispatch[:stage],
          state_file_mtime: digest_dispatch[:state_file_mtime],
          state_file_path: digest_dispatch[:state_file_path],
          hive_state_path: digest_dispatch[:hive_state_path],
          now: now,
          trigger: "digest",
          kind: :digest
        )
      rescue StandardError => e
        # If dispatch_command already spawned + recorded the child before
        # raising, `reap_completed` will call `complete` on its exit. Calling
        # `complete` here too would record a SECOND failure for one logical
        # dispatch, double-incrementing the backoff count. Only complete when
        # no child is in flight for this date (spawn failed before recording).
        if date && !@controller.running_task?(project: project, slug: date)
          @digest_scheduler&.complete(date: date, exit_code: 1, now: now)
        end
        @logger.event(:fatal, message: "digest dispatch error: #{e.class}: #{e.message}",
                              project: digest_dispatch[:project], slug: date)
      end

      def digest_dispatch_gate(project:, date:, now:)
        return :in_flight if @controller.running_task?(project: project, slug: date)

        @controller.can_dispatch_digest?(now: now)
      end

      # Consume the file-backed dispatch-request queue (plan
      # 2026-05-28-002). One pending file = one would-be `hive run`-
      # class spawn. The daemon is the single dispatcher; the bot is a
      # producer only.
      #
      # Per request, in this order:
      #   1. Parse failure / bad schema → already routed via
      #      bad_handler in DispatchRequestQueue.pending; remove and
      #      log `:dispatch_request_rejected`.
      #   2. Argv allowlist (defense in depth — the writer already
      #      validates) → remove + `:dispatch_request_rejected`.
      #   3. Expiry (10 min default) → remove +
      #      `:dispatch_request_expired`.
      #   4. Project dropped (CONFIG=78 from a prior child) → remove +
      #      `:dispatch_request_rejected reason=project_dropped`.
      #   5. Per-slug in-flight gate (controller's running_task?) →
      #      leave the file on disk, `:dispatch_request_blocked
      #      reason=in_flight`. Picked up next tick.
      #   6. Concurrency gate (caps / cooldown / quarantine) → leave
      #      the file on disk, `:dispatch_request_blocked
      #      reason=<gate>`. Picked up next tick.
      #   7. Spawn via `dispatch_command`, threading `request_id`
      #      through the supervisor so `reap_completed` can unlink the
      #      file and log `:dispatch_request_completed`.
      def process_dispatch_requests(now:)
        pending = Hive::Daemon::DispatchRequestQueue.pending(
          state_home: dispatch_request_state_home,
          bad_handler: ->(path:, reason:) {
            @logger.event(:dispatch_request_rejected,
                          path: path, reason: reason)
            # `rm_f` is idempotent — quietly does nothing if the
            # file is already gone (concurrent retry, manual cleanup).
            FileUtils.rm_f(path)
          }
        )

        # Per-slug in-flight gate within this tick: if we just spawned
        # for (project, slug) on this tick, defer subsequent requests
        # for the same slug to a later tick. The controller's
        # `running_task?` reflects spawns recorded in
        # `record_dispatch`, so this is naturally exclusive across
        # iterations of this loop too.
        pending.each do |req|
          @logger.event(:dispatch_request_observed,
                        request_id: req.request_id, project: req.project,
                        slug: req.slug, trigger: req.trigger,
                        requestor: req.requestor)

          # Per-iteration rescue: a Process.spawn failure (Errno::EAGAIN
          # / Errno::ENOMEM under fork-exhaustion) or any other
          # StandardError in dispatch_request! must not abort the rest
          # of the pending queue. The request file stays on disk for
          # the next tick to retry; the failure is logged for
          # operator visibility. Per R-01 from PR #241 ce-code-review.
          begin
            process_dispatch_request_iteration(req, now: now)
          rescue StandardError => e
            @logger.event(:dispatch_request_rejected,
                          request_id: req.request_id, project: req.project,
                          slug: req.slug,
                          reason: "spawn_failure: #{e.class}: #{e.message[0, 200]}",
                          path: req.path)
            # Don't remove the file — let the next tick try again.
            # If the failure is persistent (e.g. config corruption),
            # the operator will see repeated rejected events with
            # the same request_id.
          end
        end
      end

      # Body of one queue iteration. Extracted so the rescue in
      # process_dispatch_requests captures any error from the gate
      # checks AND the actual spawn. Returns nil; side effects via
      # @controller, @logger, and the queue's remove() call.
      def process_dispatch_request_iteration(req, now:)
        unless Hive::Daemon::DispatchRequestQueue.valid_argv?(req.argv)
          reject_request(req, reason: "invalid_argv")
          return
        end

        if Hive::Daemon::DispatchRequestQueue.expired?(req, now: now)
          expire_request(req)
          return
        end

        unless Hive::Config.find_project(req.project)
          reject_request(req, reason: "unknown_project")
          return
        end

        # C4 from PR #241 ce-code-review: gate on project_enabled? so a
        # disabled project's queued requests don't dispatch. The
        # auto-advance path (handle_row) already does this; the
        # request path must mirror to keep the single-dispatcher
        # invariant honest.
        unless project_enabled?(req.project)
          @logger.event(:dispatch_request_blocked,
                        request_id: req.request_id, project: req.project,
                        slug: req.slug, reason: "project_disabled")
          return
        end

        # Reverse the gate-evaluation order from the previous version:
        # check the cheap, deterministic running_task? gate first so an
        # in-flight slug doesn't incur the can_dispatch? scan. Per R-04
        # / M-05 from PR #241 ce-code-review.
        if @controller.running_task?(project: req.project, slug: req.slug)
          @logger.event(:dispatch_request_blocked,
                        request_id: req.request_id, project: req.project,
                        slug: req.slug, reason: "in_flight")
          return
        end

        gate = @controller.can_dispatch?(
          project: req.project, slug: req.slug, now: now,
          external_global_count: @external_active_agent_total,
          external_project_count: external_active_agent_count_for(req.project)
        )
        unless gate == :ok
          @logger.event(:dispatch_request_blocked,
                        request_id: req.request_id, project: req.project,
                        slug: req.slug, reason: gate.to_s)
          return
        end

        dispatch_request!(req, now: now)
      end

      # Build a command string from the validated argv and spawn it
      # through the same `dispatch_command` path auto-advance uses.
      #
      # C3: immediately after the spawn we CLAIM the request file —
      # rename `<id>.json` → `<id>.json.claimed` and stamp the child's
      # pid + process_start_time. The claimed file is invisible to
      # `pending`, so a later tick never re-observes (or re-dispatches)
      # it, and a daemon crash before reap leaves a claim that
      # `recover_dispatch_claims` cleans up at next start instead of
      # re-running the work. The claimed file is unlinked on reap.
      def dispatch_request!(req, now:)
        command = Shellwords.join(req.argv)
        state_file_path = resolve_request_state_file_path(req)
        preclaim_dispatch_request(req, now: now)
        pid = dispatch_command(
          command,
          project: req.project, slug: req.slug,
          # Request-driven runs don't carry a stage hint — the runner
          # resolves the task's current stage at boot. Pass nil so the
          # log line records `stage=nil` instead of inventing one.
          stage: nil,
          state_file_mtime: state_file_path && File.exist?(state_file_path) ? File.mtime(state_file_path) : nil,
          state_file_path: state_file_path,
          hive_state_path: nil,
          now: now,
          trigger: req.trigger.to_s.empty? ? "dispatch_request" : req.trigger,
          request_id: req.request_id
        )
        update_dispatch_request_claim(req, pid: pid, now: now)
        @logger.event(:dispatch_request_dispatched,
                      request_id: req.request_id, pid: pid,
                      project: req.project, slug: req.slug,
                      command: command, trigger: req.trigger,
                      chat_id: req.chat_id, update_id: req.update_id)
      rescue StandardError
        Hive::Daemon::DispatchRequestQueue.release_claim(
          req.request_id, state_home: dispatch_request_state_home
        )
        raise
      end

      def preclaim_dispatch_request(req, now:)
        claimed = Hive::Daemon::DispatchRequestQueue.claim(
          req.request_id, pid: nil, process_start_time: nil,
          now: now, state_home: dispatch_request_state_home
        )
        raise "dispatch request claim failed for #{req.request_id}" unless claimed

        claimed
      end

      def update_dispatch_request_claim(req, pid:, now:)
        start_time = pid.is_a?(Integer) && pid.positive? ? Hive::Lock.process_start_time(pid) : nil
        Hive::Daemon::DispatchRequestQueue.update_claim(
          req.request_id, pid: pid, process_start_time: start_time,
          now: now, state_home: dispatch_request_state_home
        )
      rescue StandardError => e
        @logger.event(:fatal,
                      message: "update_dispatch_request_claim raised: #{e.class}: #{e.message}",
                      keeping_previous: true)
      end

      def promote_dispatch_sequence(entry, meta, now:)
        Hive::Daemon::DispatchRequestQueue.promote_sequence(
          entry.request_id,
          project: (meta && meta[:project]) || entry.project,
          slug: (meta && meta[:slug]) || entry.slug,
          requestor: (meta && meta[:requestor]) || "bot",
          chat_id: meta && meta[:chat_id],
          update_id: meta && meta[:update_id],
          state_home: dispatch_request_state_home,
          now: now
        )
      rescue StandardError => e
        @logger.event(:fatal,
                      message: "promote_dispatch_sequence raised: #{e.class}: #{e.message}",
                      keeping_previous: true)
        # The next sequence step was NOT enqueued, so the .sequence sidecar is
        # orphaned on disk. Discard it (best-effort) so a later sweep cannot
        # resurrect a half-promoted sequence, and surface a real failure to the
        # user. Return a TRUTHY sentinel so the caller suppresses the FALSE
        # "completed" success notice — a raise here means the run did NOT fully
        # succeed. See PR #435 review.
        discard_sequence_after_failure(entry)
        notify_dispatch_failure(entry, meta, now: now, reason: "#{e.class}: #{e.message}")
        :promotion_failed
      end

      def discard_sequence_after_failure(entry)
        Hive::Daemon::DispatchRequestQueue.discard_sequence(
          entry.request_id, state_home: dispatch_request_state_home
        )
      rescue StandardError => e
        @logger.event(:fatal,
                      message: "discard_sequence_after_failure raised: #{e.class}: #{e.message}",
                      keeping_previous: true)
      end

      # C3: sweep claim files from a prior daemon process. Owner-still-
      # alive claims are left alone (we cannot reap a process we did not
      # spawn); owner-gone and aged-out claims are removed WITHOUT
      # re-dispatch (at-most-once). Each removal is logged so an operator
      # can see what the restart cleaned up.
      #
      # Known narrow window (#264): a still-alive orphan's (project, slug) is
      # NOT re-registered in the fresh controller, so for the interval until
      # that orphan exits (or its claim ages out and a later sweep removes
      # it), the per-row auto-advance path — gated only by the controller's
      # now-empty `running_task?` — could dispatch an advance for the same
      # slug. The task `.lock` is the backstop that still prevents two live
      # runs of the same task; it is a narrower guarantee than an in-flight
      # controller slot but holds across the daemon restart. Re-registering
      # the orphan in the controller was deliberately rejected: without a
      # supervised child to reap, the slot would only free on claim age-out
      # (up to CLAIM_EXPIRY_SEC), trading a narrow already-backstopped window
      # for a guaranteed multi-hour stuck slot. See [[modules/daemon]].
      def recover_dispatch_claims(now:)
        alive = lambda do |pid, recorded_start_time|
          next false unless pid.is_a?(Integer) && pid.positive?
          next false unless process_alive?(pid)
          # If both start times are present and differ, the PID was
          # reused — the original child is gone. A nil on either side is
          # unverifiable; treat as alive so we never drop a claim for a
          # genuinely running orphan.
          live_start = Hive::Lock.process_start_time(pid)
          recorded = recorded_start_time
          next true if recorded.nil? || live_start.nil?

          recorded.to_s == live_start.to_s
        end

        Hive::Daemon::DispatchRequestQueue.recover_claims(
          state_home: dispatch_request_state_home, now: now, alive: alive,
          expiry_sec: claim_expiry_sec,
          handler: ->(request_id:, reason:, path:) {
            @logger.event(:dispatch_request_recovered,
                          request_id: request_id, reason: reason, path: path)
          }
        )
      rescue StandardError => e
        @logger.event(:fatal,
                      message: "recover_dispatch_claims raised: #{e.class}: #{e.message}",
                      keeping_previous: true)
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # C3 (#5): age a claim out only after the child's full run budget
      # could plausibly have elapsed — child_timeout_sec + kill grace + a
      # couple of poll intervals + margin. EXPIRY_SEC (the unclaimed-
      # request window, 600s) is far too short: it would drop a live
      # ~90-min run's claim 10 minutes into a restart. When the timeout is
      # disabled (child_timeout_sec=0, no bound) fall back to the queue's
      # generous CLAIM_EXPIRY_SEC.
      def claim_expiry_sec
        timeout = @daemon_cfg.fetch(
          "child_timeout_sec", Hive::Config::DEFAULTS.dig("daemon", "child_timeout_sec")
        ).to_i
        return Hive::Daemon::DispatchRequestQueue::CLAIM_EXPIRY_SEC unless timeout.positive?

        grace = @daemon_cfg.fetch("child_kill_grace_sec", ChildSupervisor::DEFAULT_KILL_GRACE_SEC).to_i
        timeout + grace + (@poll_interval_sec.to_i * 2) + 600
      end

      # ADV-1 (#6): drop stale dispatch-result notices each tick so a
      # down/wedged bot can't let the dir grow without bound. The bot
      # itself also skips+removes stale notices on drain; this is the
      # daemon-side backstop for when no bot is consuming at all. Never
      # crashes a tick.
      def prune_dispatch_results(now:)
        Hive::Daemon::DispatchResultQueue.prune_expired(
          state_home: dispatch_result_state_home, now: now
        )
      rescue StandardError => e
        @logger.event(:fatal,
                      message: "prune_dispatch_results raised: #{e.class}: #{e.message}",
                      keeping_previous: true)
      end

      # ADV-1: write a completion-notice file the bot will drain + relay to
      # the originating Telegram chat. No-op when the completed run did
      # not carry a chat_id (auto-advance runs, or metadata already gone)
      # — there's no one to reply to. Best-effort: a write failure must
      # never crash a tick, so it's logged and swallowed.
      def notify_dispatch_result(entry, meta, now:)
        chat_id = meta && meta[:chat_id]
        return if chat_id.nil?

        Hive::Daemon::DispatchResultQueue.write!(
          chat_id: chat_id, update_id: meta[:update_id],
          project: entry.project, slug: entry.slug,
          request_id: entry.request_id, exit_code: entry.exit_code,
          command: entry.command, now: now,
          state_home: dispatch_result_state_home
        )
        @logger.event(:dispatch_result_written,
                      request_id: entry.request_id, project: entry.project,
                      slug: entry.slug, exit_code: entry.exit_code, chat_id: chat_id)
      rescue StandardError => e
        @logger.event(:fatal,
                      message: "notify_dispatch_result raised: #{e.class}: #{e.message}",
                      keeping_previous: true)
      end

      # Surface a sequence-promotion failure back to the originating chat.
      # The completed step itself exited 0, but the NEXT step was never
      # enqueued, so we must NOT report success. We write a result notice with
      # a synthetic non-zero exit code so the bot renders its failure message
      # (see Hive::Bot::Supervisor#dispatch_result_text) instead of staying
      # silent. See PR #435 review.
      def notify_dispatch_failure(entry, meta, now:, reason:)
        chat_id = meta && meta[:chat_id]
        return if chat_id.nil?

        Hive::Daemon::DispatchResultQueue.write!(
          chat_id: chat_id, update_id: meta[:update_id],
          project: entry.project, slug: entry.slug,
          request_id: entry.request_id,
          exit_code: Hive::ExitCodes::SOFTWARE,
          command: entry.command, now: now,
          state_home: dispatch_result_state_home
        )
        @logger.event(:dispatch_sequence_promotion_failed,
                      request_id: entry.request_id, project: entry.project,
                      slug: entry.slug, chat_id: chat_id, reason: reason)
      rescue StandardError => e
        @logger.event(:fatal,
                      message: "notify_dispatch_failure raised: #{e.class}: #{e.message}",
                      keeping_previous: true)
      end

      def reject_request(req, reason:)
        @logger.event(:dispatch_request_rejected,
                      request_id: req.request_id, project: req.project,
                      slug: req.slug, reason: reason, path: req.path)
        Hive::Daemon::DispatchRequestQueue.remove(
          req.request_id, state_home: dispatch_request_state_home
        )
      end

      def expire_request(req)
        @logger.event(:dispatch_request_expired,
                      request_id: req.request_id, project: req.project,
                      slug: req.slug, created_at: req.created_at.utc.iso8601,
                      path: req.path)
        Hive::Daemon::DispatchRequestQueue.remove(
          req.request_id, state_home: dispatch_request_state_home
        )
      end

      # Best-effort lookup of the task's CURRENT state file so the
      # post-completion mtime refresh inside `reap_completed` has a
      # path to stat. Mirrors `find_post_advance_state_file` but
      # without the at-dispatch path (a request carries no stage hint).
      def resolve_request_state_file_path(req)
        project_entry = Hive::Config.find_project(req.project)
        return nil unless project_entry

        find_post_advance_state_file(project_entry["hive_state_path"], req.slug)
      end

      def dispatch_request_state_home
        @dispatch_request_state_home || Hive::Paths.state_home
      end

      def dispatch_result_state_home
        @dispatch_result_state_home || Hive::Paths.state_home
      end

      def dispatch_command(command, project:, slug:, stage:, state_file_mtime:,
                           state_file_path:, hive_state_path:, now:, trigger: "advance",
                           request_id: nil, kind: :task)
        if @dry_run
          @logger.event(:dry_run, project: project, slug: slug, stage: stage,
                                  command: command)
        end
        pid = @supervisor.spawn(
          command_string: command,
          project: project, slug: slug, stage: stage,
          hive_state_path: hive_state_path,
          state_file_path: state_file_path,
          dry_run: @dry_run,
          request_id: request_id
        )
        @controller.record_dispatch(
          pid: pid, project: project, slug: slug, stage: stage,
          command: command, started_at: now, state_file_mtime: state_file_mtime,
          kind: kind
        )
        @logger.event(:dispatched, pid: pid, project: project, slug: slug,
                                   stage: stage, command: command, trigger: trigger,
                                   dry_run: @dry_run)
        @dispatched_today += 1
        pid
      end

      def enqueue_merge_watch(row, error_reason: nil)
        return unless @merge_watcher

        @merge_watcher.enqueue(project: row.project, slug: row.slug,
                               task_folder: row.folder,
                               error_reason: error_reason)
        @logger.event(:merge_watcher_enqueued, project: row.project, slug: row.slug,
                                               folder: row.folder,
                                               error_reason: error_reason)
      end

      def merged_pr_recoverable_finalize_error?(row)
        return false unless row.stage.to_s == Hive::Daemon::PrMergeWatcher::ARCHIVE_FROM_STAGE
        return false unless row.marker.to_s == "error"
        return false unless row.action.to_s == "error"

        reason = row.marker_attrs.to_h["reason"].to_s
        Hive::Daemon::PrMergeWatcher::MERGED_PR_RECOVERABLE_ERROR_REASONS.include?(reason)
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
        @digest_cfg = Hive::Config.load_global_digest_block
        @config = { "daemon" => @daemon_cfg, "update" => @update_cfg, "digest" => @digest_cfg }
        @update_check_enabled = @update_cfg.fetch("check", true)
        # Reconfigure the digest scheduler in place so enabling the digest
        # (or retuning max_catchup_days) via config + SIGHUP takes effect
        # within one tick, consistent with the rest of the daemon's reload
        # contract — without losing the scheduler's in-flight state.
        @digest_scheduler&.reconfigure(
          enabled: @digest_cfg.fetch("enabled", false),
          max_catchup_days: @digest_cfg.fetch(
            "max_catchup_days", Hive::Daemon::DigestScheduler::DEFAULT_MAX_CATCHUP_DAYS
          )
        )
        @edit_debounce_sec = @daemon_cfg.fetch("edit_debounce_sec", 30)
        @shutdown_grace_sec = @daemon_cfg.fetch("shutdown_grace_sec", 600)
        @poll_interval_sec = @daemon_cfg.fetch("poll_interval_sec", 30)
        @fast_poll_sec = @daemon_cfg.fetch("fast_poll_sec", 1)
        # R-02: push reloaded child-timeout knobs into the supervisor so
        # an operator tuning daemon.child_timeout_sec / verb overrides via
        # SIGHUP takes effect for children spawned after the reload.
        # (Every supervisor implements `update_timeouts`; the `respond_to?`
        # seam was removed in #252.)
        @supervisor.update_timeouts(
          default_timeout_sec: @daemon_cfg.fetch(
            "child_timeout_sec", Hive::Config::DEFAULTS.dig("daemon", "child_timeout_sec")
          ),
          verb_timeouts: @daemon_cfg.fetch("child_verb_timeouts", {}),
          kill_grace_sec: @daemon_cfg.fetch(
            "child_kill_grace_sec", ChildSupervisor::DEFAULT_KILL_GRACE_SEC
          )
        )
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
        # Rebuild alongside the healer on SIGHUP reload so a future
        # operator-tunable knob (e.g. max_per_tick) would take effect
        # within one tick; today it carries only the dry_run flag.
        @display_name_backfiller = DisplayNameBackfiller.new(
          logger: @logger,
          dry_run: @dry_run
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
