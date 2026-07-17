require "set"
require "date"

module Hive
  module Daemon
    # In-memory bookkeeper for "may we spawn a child for this
    # (project, slug) right now?" plus retry / cooldown / quarantine /
    # daily-rate state across the daemon's lifetime.
    #
    # The controller is the single load-bearing budget gate inside the
    # daemon. Per-task `.lock` (ADR-007) is the last-resort safety net,
    # but the goal is to prevent the daemon from racing toward the lock
    # in the first place — the controller is what stops 40 enrolled
    # projects from fanning out 40 simultaneous `hive run` children.
    #
    # State is in-memory only; restart clears everything (cooldowns and
    # quarantines included). The trade-off is operational: a daemon
    # crash + restart re-attempts a quarantined task once, which is
    # safer than persisting bad state across restarts and worse only
    # when the same task is genuinely permanently broken.
    class ConcurrencyController
      # Protective backoff after a WRONG_STAGE exit. WRONG_STAGE usually
      # means another actor advanced the task or classification raced a
      # marker change, so backing off avoids retry churn while the next
      # status scan catches up.
      WRONG_STAGE_BACKOFF_SEC = 60

      # Transient-failure backoff schedule (seconds). After the Nth
      # consecutive transient failure on the same (project, slug),
      # the entry's cooldown becomes the Nth element. Past the end of
      # the schedule, the entry is quarantined.
      TRANSIENT_BACKOFF_SCHEDULE = [ 60, 120, 300 ].freeze

      attr_reader :max_concurrent_runs, :max_concurrent_per_project,
                  :max_runs_per_day_per_project, :max_concurrent_patrol_scans

      def initialize(max_concurrent_runs:, max_concurrent_per_project:, max_runs_per_day_per_project:,
                     max_concurrent_patrol_scans: 1, dispatch_state: nil)
        @max_concurrent_runs = max_concurrent_runs
        @max_concurrent_per_project = max_concurrent_per_project
        @max_runs_per_day_per_project = max_runs_per_day_per_project
        # Patrol SCANS (`hive patrol PROJECT`) run on a SEPARATE budget so a
        # long codex-backed scan never consumes a task-dispatch slot. They
        # are tagged `kind: :patrol_scan` in @running and excluded from the
        # task caps below; this counter bounds them independently.
        @max_concurrent_patrol_scans = max_concurrent_patrol_scans
        # Optional Hive::Daemon::DispatchBaselines store. When present, the
        # `[project, slug] => mtime` baseline map survives daemon restarts so
        # an already-answered needs_input row isn't re-stranded on first sight
        # (Policy#decide_edit relies on this baseline). nil = in-memory only.
        # The store owns its own logger and emits the full set of typed events
        # (`:daemon_dispatch_baselines_*`) for both expected I/O errors and the
        # defense-in-depth broad-StandardError rescue.
        @dispatch_state = dispatch_state

        # pid → { project, slug, stage, command, started_at, state_file_mtime_at_dispatch }
        @running = {}
        @external_running_by_project = Hash.new(0)
        @external_running_global = 0
        @durable_daily_counts = {}
        # [project, Date] → Integer
        @daily_counts = Hash.new(0)
        # [project, slug] → Time (cooldown expiry)
        @cooldown_until = {}
        # [project, slug] → Integer (count of consecutive transient failures)
        @transient_failures = Hash.new(0)
        # Set<[project, slug]>
        @quarantine = Set.new
        # Set<project> (post-CONFIG=78)
        @dropped_projects = Set.new
        # [project, slug] → Time (mtime LAST observed on the state file —
        # at dispatch, post-completion refresh, or `:record_baseline` seed;
        # see `observe_state_file_mtime` / `record_dispatch`). Seeded from
        # the persisted store so a restart keeps the baselines the next
        # tick compares against (fail-closed: {} if absent/corrupt).
        @last_dispatched_mtime = @dispatch_state ? @dispatch_state.load : {}
      end

      # Apply SIGHUP-reloaded budget limits without replacing the controller.
      # Rebuilding it would discard live child accounting, cooldowns,
      # quarantine, daily counters, and persisted-baseline state.
      def update_limits(max_concurrent_runs:, max_concurrent_per_project:,
                        max_runs_per_day_per_project:, max_concurrent_patrol_scans:)
        @max_concurrent_runs = max_concurrent_runs
        @max_concurrent_per_project = max_concurrent_per_project
        @max_runs_per_day_per_project = max_runs_per_day_per_project
        @max_concurrent_patrol_scans = max_concurrent_patrol_scans
      end

      # Predicate: can the daemon spawn a child for (project, slug) now?
      #
      # `external_*_count` is the dispatcher's per-tick snapshot of
      # active agent rows already visible in `hive status --json` but not
      # owned by this controller. That lets a daemon restart respect
      # work already in flight while keeping waiting rows (`needs_input`,
      # recovery states, etc.) out of the cap.
      # Returns one of :ok | :global_cap | :project_cap | :daily_cap |
      #   :cooldown | :quarantined | :project_dropped
      def can_dispatch?(project:, slug:, now: Time.now,
                        external_global_count: 0, external_project_count: 0)
        return :project_dropped if @dropped_projects.include?(project)
        return :quarantined     if @quarantine.include?([ project, slug ])

        cooldown_expiry = @cooldown_until[[ project, slug ]]
        return :cooldown if cooldown_expiry && cooldown_expiry > now

        external_global = [ @external_running_global, external_global_count.to_i ].max
        external_project = [ @external_running_by_project[project].to_i, external_project_count.to_i ].max
        # Task caps count only task-kind runs; patrol scans live on their
        # own budget (see can_dispatch_patrol_scan?) so a running scan never
        # eats a task slot.
        active_global_count = task_running_count + external_global
        active_project_count = task_running_count(project: project) + external_project

        return :global_cap  if active_global_count >= @max_concurrent_runs
        return :project_cap if active_project_count >= @max_concurrent_per_project
        return :daily_cap   if daily_count_for(project, now) >= @max_runs_per_day_per_project

        :ok
      end

      # Gate for a patrol SCAN dispatch. Scans have their own concurrency
      # budget so they never compete with task dispatch for the global cap.
      # `max_concurrent_patrol_scans` is a PER-PROJECT cap: count only the
      # given project's running scans so different projects patrol in
      # parallel (a global count would serialize/starve projects when the
      # cap is 1).
      #   :ok | :project_dropped | :patrol_scan_cap
      def can_dispatch_patrol_scan?(project:, now: Time.now)
        return :project_dropped if @dropped_projects.include?(project)

        scan_count = @running.count { |_pid, entry| entry[:kind] == :patrol_scan && entry[:project] == project }
        return :patrol_scan_cap if scan_count >= @max_concurrent_patrol_scans

        :ok
      end

      # Gate for the global daily digest dispatch. Like patrol scans, the
      # digest runs on its OWN budget (tagged `kind: :digest`, excluded
      # from the task caps below) so it never holds a task slot or pushes
      # the daemon transiently past `max_concurrent_runs`. At most one
      # digest child runs at a time.
      #   :ok | :digest_in_flight
      def can_dispatch_digest?(now: Time.now)
        return :digest_in_flight if @running.any? { |_pid, entry| entry[:kind] == :digest }

        :ok
      end

      # Number of running task-kind dispatches (patrol scans and the global
      # digest excluded), optionally scoped to one project.
      def task_running_count(project: nil)
        @running.count do |_pid, entry|
          next false if entry[:kind] == :patrol_scan || entry[:kind] == :digest

          project.nil? || entry[:project] == project
        end
      end

      # Refresh counts for active agent rows discovered from `hive status`
      # that were not spawned by this daemon process. This keeps caps
      # restart-safe: after a daemon restart, visible `agent_running` rows
      # still consume global/per-project capacity until they finish.
      def set_external_running_counts(per_project:)
        @external_running_by_project = Hash.new(0)
        per_project.each do |project, count|
          @external_running_by_project[project] = count.to_i if count.to_i.positive?
        end
        @external_running_global = @external_running_by_project.values.sum
      end

      # Publish the reconciled durable view before admission. Legacy status
      # counts passed here must already be deduplicated against lease-backed
      # tasks; they are a compatibility fallback only.
      def set_capacity_snapshot(snapshot, legacy_per_project: {})
        combined = Hash.new(0)
        snapshot.per_project.each { |project, count| combined[project] += count.to_i }
        legacy_per_project.each { |project, count| combined[project] += count.to_i }
        @external_running_by_project = combined
        @external_running_global = snapshot.global_count.to_i + legacy_per_project.values.sum(&:to_i)
        @durable_daily_counts = snapshot.daily_counts
      end

      # Returns the mtime LAST observed on (project, slug)'s state file —
      # captured at dispatch time AND refreshed post-completion (so the
      # agent's own marker write doesn't look like a user edit on the
      # next tick), AND seeded by Policy's `:record_baseline` decision
      # on first-sight `kind: edit` rows.
      #
      # Returns nil if no prior observation is recorded (first-ever
      # sight of this task in this daemon's lifetime).
      def last_dispatched_state_file_mtime_for(project:, slug:)
        @last_dispatched_mtime[[ project, slug ]]
      end

      # Update the recorded mtime without consuming a dispatch slot.
      # Used by the Dispatcher in two flows: (a) when Policy returns
      # `:record_baseline` on a first-sight `kind: edit` row, the
      # dispatcher seeds the controller with the current mtime so the
      # next tick has something to compare against; (b) post-child-
      # completion, the dispatcher refreshes the recorded mtime to the
      # current state-file mtime so the agent's own `_WAITING`-marker
      # write (which moves mtime past the at-dispatch value) doesn't
      # trigger a redundant re-dispatch on the next tick.
      def observe_state_file_mtime(project:, slug:, mtime:)
        return if mtime.nil?

        @last_dispatched_mtime[[ project, slug ]] = mtime
        persist_dispatch_baselines!
      end

      # Record a fresh dispatch. Caller is the dispatcher AFTER the
      # supervisor's spawn returns a real PID. Consumes one daily-rate
      # slot for the (project, today) pair (refunded later if the run
      # exits with TEMPFAIL — see record_completion).
      def record_dispatch(pid:, project:, slug:, stage:, command:,
                          started_at:, state_file_mtime:, kind: :task)
        @running[pid] = {
          project: project,
          slug: slug,
          stage: stage,
          command: command,
          started_at: started_at,
          state_file_mtime_at_dispatch: state_file_mtime,
          kind: kind
        }
        # Digest and patrol scans run on their own gates, which read NO daily
        # task counts, and record_completion returns before the TEMPFAIL refund
        # for both kinds. Counting either dispatch would therefore consume an
        # ordinary task slot that can never be refunded, so exempt both.
        unless %i[digest patrol_scan].include?(kind)
          @daily_counts[[ project, started_at.to_date ]] += 1
        end
        if state_file_mtime
          @last_dispatched_mtime[[ project, slug ]] = state_file_mtime
          persist_dispatch_baselines!
        end
      end

      # Drop persisted baselines for tasks no longer present in a successful
      # status scan, so the file doesn't grow unbounded as tasks are archived
      # or dropped. `live_keys` is the authoritative set of [project, slug]
      # pairs the dispatcher saw this tick. The dispatcher only calls this on
      # an overall-successful fetch (never on a transient empty/failed scan).
      #
      # `scope_projects` is REQUIRED: only baselines whose project is in this
      # set get a chance to be pruned. The dispatcher passes `result.projects`
      # so per-project status errors (`not_initialised`, `missing_project_path`)
      # — which filter a project out of both `Result#rows` AND `Result#projects`
      # for transient NFS hiccups, `hive forget` races, or re-bootstrapping
      # projects — keep their baselines untouched. Letting this kwarg default
      # would silently re-strand answered tasks the next time those failures
      # hit, which is the exact regression the persistence layer exists to
      # prevent. Pass an empty set to short-circuit pruning entirely.
      def prune_dispatch_baselines(live_keys, scope_projects:)
        live = live_keys.to_set
        scope = scope_projects.to_set
        before = @last_dispatched_mtime.size
        @last_dispatched_mtime.select! do |(project, slug), _value|
          # Out-of-scope projects (errored this tick) keep their baselines.
          next true unless scope.include?(project)

          live.include?([ project, slug ])
        end
        persist_dispatch_baselines! if @last_dispatched_mtime.size != before
      end

      # Record a child completion. Side-effects on cooldown / quarantine
      # / daily-counter depend on exit_code per Hive::ExitCodes:
      #
      #   0  SUCCESS              → no cooldown; next stage may dispatch immediately
      #   3  TASK_IN_ERROR        → no cooldown (marker handles re-entry policy via Policy)
      #   4  WRONG_STAGE          → 1 min cooldown (race or classifier bug; back off)
      #   64 USAGE                → quarantine for daemon lifetime
      #   75 TEMPFAIL             → no cooldown, refund daily-rate slot, allow retry
      #   78 CONFIG               → drop the entire project
      #   1/70/other              → transient: backoff (60/120/300s) then quarantine
      def record_completion(pid:, exit_code:, completed_at: Time.now)
        entry = @running.delete(pid)
        return unless entry

        # Global digests and patrol scans run on scheduler-level backoff and
        # their gates consult none of the per-task maps below. Recording
        # cooldown/quarantine/dropped state here would either leak never-read
        # entries or, for a patrol-only CONFIG error, strand unrelated project
        # tasks. Freeing the matching capacity slot above is all they need.
        return if %i[digest patrol_scan].include?(entry[:kind])

        key = [ entry[:project], entry[:slug] ]

        case exit_code
        when Hive::ExitCodes::SUCCESS
          @transient_failures.delete(key)
        when Hive::ExitCodes::TASK_IN_ERROR
          @transient_failures.delete(key)
          # Marker now classifies as recover_stale → Policy returns :skip;
          # no controller-level quarantine needed.
        when Hive::ExitCodes::WRONG_STAGE
          @cooldown_until[key] = completed_at + WRONG_STAGE_BACKOFF_SEC
        when Hive::ExitCodes::USAGE
          @quarantine.add(key)
          @transient_failures.delete(key)
        when Hive::ExitCodes::TEMPFAIL
          # Refund daily-rate slot — TEMPFAIL means we didn't actually
          # do work (lock held by a concurrent runner). The dispatcher
          # will retry next poll once the lock clears.
          dec_daily(entry[:project], entry[:started_at])
          @transient_failures.delete(key)
        when Hive::ExitCodes::CONFIG
          @dropped_projects.add(entry[:project])
        else
          # Transient failures: 1, 70, or any other non-typed code.
          n = @transient_failures[key] += 1
          if n > TRANSIENT_BACKOFF_SCHEDULE.size
            @quarantine.add(key)
          else
            @cooldown_until[key] = completed_at + TRANSIENT_BACKOFF_SCHEDULE[n - 1]
          end
        end
      end

      # Drop a project from active dispatch for the daemon's lifetime.
      # Direct API for callers (e.g., dispatcher catching a CONFIG=78
      # before a child even spawns).
      def record_project_dropped(project:)
        @dropped_projects.add(project)
      end

      def running_pids
        @running.keys
      end

      def running_task?(project:, slug:)
        @running.any? do |_pid, entry|
          entry[:project] == project && entry[:slug] == slug
        end
      end

      def in_flight_count
        @running.size + @external_running_global
      end

      def quarantined?(project:, slug:)
        @quarantine.include?([ project, slug ])
      end

      def project_dropped?(project)
        @dropped_projects.include?(project)
      end

      def dropped_projects
        @dropped_projects.to_a
      end

      def daily_count_for(project, now = Time.now)
        [ @daily_counts[[ project, now.to_date ]],
          @durable_daily_counts.fetch([ project, now.to_date ], 0) ].max
      end

      private

      # Write-through the baseline map to the persisted store. The store
      # owns the entire error-handling surface: narrow IOError/SystemCallError
      # rescues + a defense-in-depth broad StandardError rescue, each surfacing
      # a typed `:daemon_dispatch_baselines_*` event. The controller stays
      # ignorant of file I/O.
      def persist_dispatch_baselines!
        @dispatch_state&.write(@last_dispatched_mtime)
      end

      def running_count_for(project)
        @running.count { |_pid, entry| entry[:project] == project } +
          @external_running_by_project[project].to_i
      end

      def dec_daily(project, started_at)
        key = [ project, started_at.to_date ]
        @daily_counts[key] -= 1
        @daily_counts.delete(key) if @daily_counts[key] <= 0
      end
    end
  end
end
