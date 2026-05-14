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
      # Default cooldown after a SUCCESS exit. Prevents a happy task
      # from re-firing on the next tick before the user sees the result.
      SUCCESS_COOLDOWN_SEC = 300

      # Transient-failure backoff schedule (seconds). After the Nth
      # consecutive transient failure on the same (project, slug),
      # the entry's cooldown becomes the Nth element. Past the end of
      # the schedule, the entry is quarantined.
      TRANSIENT_BACKOFF_SCHEDULE = [ 60, 120, 300 ].freeze

      attr_reader :max_concurrent_runs, :max_concurrent_per_project, :max_runs_per_day_per_project

      def initialize(max_concurrent_runs:, max_concurrent_per_project:, max_runs_per_day_per_project:)
        @max_concurrent_runs = max_concurrent_runs
        @max_concurrent_per_project = max_concurrent_per_project
        @max_runs_per_day_per_project = max_runs_per_day_per_project

        # pid → { project, slug, stage, command, started_at, state_file_mtime_at_dispatch }
        @running = {}
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
        # [project, slug] → Time (mtime of state file at last dispatch)
        @last_dispatched_mtime = {}
      end

      # Predicate: can the daemon spawn a child for (project, slug) now?
      #
      # `external_*_count` is the dispatcher's per-tick snapshot of
      # active agent rows already visible in `hive status --json` but not
      # owned by this controller. That lets a daemon restart respect
      # work already in flight while keeping waiting rows (`needs_input`,
      # `review_findings`, recovery states, etc.) out of the cap.
      # Returns one of :ok | :global_cap | :project_cap | :daily_cap |
      #   :cooldown | :quarantined | :project_dropped
      def can_dispatch?(project:, slug:, now: Time.now,
                        external_global_count: 0, external_project_count: 0)
        return :project_dropped if @dropped_projects.include?(project)
        return :quarantined     if @quarantine.include?([ project, slug ])

        cooldown_expiry = @cooldown_until[[ project, slug ]]
        return :cooldown if cooldown_expiry && cooldown_expiry > now

        active_global_count = @running.size + external_global_count
        active_project_count = running_count_for(project) + external_project_count

        return :global_cap  if active_global_count >= @max_concurrent_runs
        return :project_cap if active_project_count >= @max_concurrent_per_project
        return :daily_cap   if daily_count_for(project, now) >= @max_runs_per_day_per_project

        :ok
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
      end

      # Record a fresh dispatch. Caller is the dispatcher AFTER the
      # supervisor's spawn returns a real PID. Consumes one daily-rate
      # slot for the (project, today) pair (refunded later if the run
      # exits with TEMPFAIL — see record_completion).
      def record_dispatch(pid:, project:, slug:, stage:, command:,
                          started_at:, state_file_mtime:)
        @running[pid] = {
          project: project,
          slug: slug,
          stage: stage,
          command: command,
          started_at: started_at,
          state_file_mtime_at_dispatch: state_file_mtime
        }
        @daily_counts[[ project, started_at.to_date ]] += 1
        @last_dispatched_mtime[[ project, slug ]] = state_file_mtime if state_file_mtime
      end

      # Record a child completion. Side-effects on cooldown / quarantine
      # / daily-counter depend on exit_code per Hive::ExitCodes:
      #
      #   0  SUCCESS              → 5 min cooldown
      #   3  TASK_IN_ERROR        → no cooldown (marker handles re-entry policy via Policy)
      #   4  WRONG_STAGE          → 5 min cooldown (race or classifier bug; back off)
      #   64 USAGE                → quarantine for daemon lifetime
      #   75 TEMPFAIL             → no cooldown, refund daily-rate slot, allow retry
      #   78 CONFIG               → drop the entire project
      #   1/70/other              → transient: backoff (60/120/300s) then quarantine
      def record_completion(pid:, exit_code:, completed_at: Time.now)
        entry = @running.delete(pid)
        return unless entry

        key = [ entry[:project], entry[:slug] ]

        case exit_code
        when Hive::ExitCodes::SUCCESS
          @cooldown_until[key] = completed_at + SUCCESS_COOLDOWN_SEC
          @transient_failures.delete(key)
        when Hive::ExitCodes::TASK_IN_ERROR
          @transient_failures.delete(key)
          # Marker now classifies as recover_stale → Policy returns :skip;
          # no controller-level quarantine needed.
        when Hive::ExitCodes::WRONG_STAGE
          @cooldown_until[key] = completed_at + SUCCESS_COOLDOWN_SEC
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
        @running.size
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
        @daily_counts[[ project, now.to_date ]]
      end

      private

      def running_count_for(project)
        @running.count { |_pid, entry| entry[:project] == project }
      end

      def dec_daily(project, started_at)
        key = [ project, started_at.to_date ]
        @daily_counts[key] -= 1
        @daily_counts.delete(key) if @daily_counts[key] <= 0
      end
    end
  end
end
