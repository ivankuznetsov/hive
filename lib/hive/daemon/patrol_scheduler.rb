require "json"
require "open3"
require "shellwords"
require "time"
require "hive/config"
require "hive/git_ops"
require "hive/patrol/decision_projection"
require "hive/patrol/launch_budget"
require "hive/patrol/state_store"
require "hive/one_shot/schedule_state"
require "hive/workflows"

module Hive
  module Daemon
    # Slow-cadence collaborator that decides which registered projects
    # should receive one `hive patrol PROJECT --json` scan cycle. It only
    # returns dispatch hashes; Dispatcher still owns daemon.enabled,
    # legacy-layout, dry-run, and concurrency gates before spawning.
    class PatrolScheduler
      PATROL_STAGE = "patrol".freeze
      PATROL_SLUG = "patrol".freeze
      FAILURE_BACKOFF_SCHEDULE = [ 60, 300, 900 ].freeze

      class GitHelper
        def default_branch(project_root, cfg:)
          cfg["default_branch"] || Hive::GitOps.new(project_root).detect_default_branch
        end

        def rev_parse(project_root, ref)
          out, err, status = Open3.capture3("git", "-C", project_root, "rev-parse", ref)
          raise Hive::GitError, "git rev-parse #{ref} failed: #{err.strip.empty? ? out : err}" unless status.success?

          out.strip
        end
      end

      def initialize(registry: -> { Hive::Config.registered_projects },
                     config_loader: ->(path) { Hive::Config.load(path) },
                     git: GitHelper.new, state_store_factory: nil,
                     schedule_state_factory: nil,
                     database: Hive::RuntimeControlPlane.database)
        @registry = registry
        @config_loader = config_loader
        @git = git
        @database = database
        @state_store_factory = state_store_factory || lambda do |entry|
          Hive::Patrol::StateStore.new(
            entry.fetch("path"), hive_state_path: entry.fetch("hive_state_path")
          )
        end
        @schedule_state_factory = schedule_state_factory || lambda do |entry|
          Hive::OneShot::ScheduleState.new(state_root: entry.fetch("hive_state_path"))
        end
        @pending = {}
        @failures = {}
        @next_check_at = {}
        @post_reserve_at = {}
        @loaded_gates = {}
        @observations = {}
        @events = []
      end

      def tick(now: Time.now)
        candidates(now: now).filter_map { |candidate| reserve(candidate, now: now) }
      end

      # Side-effect-free with respect to dispatch ownership: callers may
      # compare ordinary and architecture work without consuming a patrol
      # turn (`@pending` is touched only by reserve/complete/cancel).
      # Not-due checks commit their next evaluation deadline, but a due
      # candidate remains eligible until `reserve` acquires dispatch
      # ownership. Timer schedules wake at their exact due time rather than
      # a full poll interval after the most recent daemon scan.
      def candidates(now: Time.now, projects: nil, bypass_observation_throttle: false,
                     persist: true, strict: false)
        @events.clear
        dispatches = []
        selected = Array(projects).map(&:to_s) if projects
        @registry.call.each do |entry|
          project = entry.fetch("name")
          next if selected && !selected.include?(project.to_s)

          load_gates(entry)
          if pending?(project)
            observe(project, :waiting_external, "worker_active")
            next
          end
          if (deadline = blocked_until(project, now))
            observe(project, :waiting_external, "cadence", deadline)
            next
          end
          # Slow patrol cadence (U2): once a project has been evaluated,
          # don't re-run its per-project git/config checks until
          # poll_interval_sec has elapsed. Without this the `new_commits`
          # trigger shells out to `git rev-parse` on every daemon tick
          # (~30s) instead of the configured patrol interval. A project
          # with an outstanding failure is exempt so its backoff schedule
          # governs the retry rather than the slow poll.
          if !bypass_observation_throttle && throttled?(project, now)
            observe(project, :waiting_external, "observation_throttled", @next_check_at[project])
            next
          end

          cfg = @config_loader.call(entry.fetch("path"))
          patrol = cfg.fetch("patrol", {})
          unless Hive::Workflows.coding_id?(cfg["default_workflow"])
            @next_check_at[project] = now + patrol.fetch("poll_interval_sec", 600).to_i
            persist_gates(entry, now: now) if persist
            observe(project, :disabled, "non_coding_workflow")
            next
          end
          # Throttle every project we evaluate, including opted-out ones:
          # each branch below commits `@next_check_at` once the project's
          # config has been loaded. Otherwise a disabled project would
          # reload its full config on every ~30s tick just to rediscover
          # patrol.enabled: false. A project that flips to enabled
          # mid-interval is picked up on its next poll window.
          state = read_state(entry)
          selection_input = schedule_selection_input(
            entry, cfg, patrol, now, state: state
          )
          selection = Hive::Patrol::DecisionProjection.project(selection_input)
          unless selection.rationale == "due"
            @next_check_at[project] = next_schedule_check_at(
              state, patrol, selection_input, now
            )
            persist_gates(entry, now: now) if persist
            if selection_input.fetch("enabled")
              observe(project, :waiting_external, selection.rationale,
                      @next_check_at[project], trigger: selection_input.fetch("trigger"))
            else
              observe(project, :disabled, "disabled")
            end
            next
          end
          unless launch_capacity_available?(entry, cfg, now)
            persist_gates(entry, now: now) if persist
            observe(project, :waiting_external, "launch_capacity",
                    @next_check_at[project])
            next
          end

          observe(project, :runnable_now, "due")
          dispatches << dispatch_for(entry)
        rescue Hive::ConfigError, Hive::GitError, KeyError => error
          raise if strict

          @observations[project] = { state: :error, reason: error.message }
          next
        end
        dispatches
      end

      def readiness(project:, now: Time.now, persist: false)
        candidates(
          now: now, projects: [ project ], bypass_observation_throttle: true,
          persist: persist, strict: true
        )
        observation = @observations.fetch(project.to_s, { state: :disabled })
        readiness_item(project.to_s, observation)
      end

      def drain_events
        drained = @events.dup
        @events.clear
        drained
      end

      def reserve(candidate, now: Time.now)
        project = candidate.fetch(:project)
        entry = current_entry_for(project, candidate.fetch(:entry))
        return nil unless entry
        return nil if pending?(project)
        # Candidate discovery may run beside the daemon's authoritative task
        # tick. A Patrol child can fail after this hint was produced but before
        # the main thread reserves it; recheck the newer backoff here so a
        # stale hint cannot immediately undo failure pacing.
        load_gates(entry)
        return nil if blocked_until(project, now)

        cfg = @config_loader.call(entry.fetch("path"))
        return nil unless cfg.dig("patrol", "enabled") == true
        return nil unless Hive::Workflows.coding_id?(cfg["default_workflow"])
        return nil unless launch_capacity_available?(entry, cfg, now)
        cycle_admitted, = state_store(entry).try_with_cycle_admission { true }
        return nil unless cycle_admitted
        @pending[project] = {
          started_at: now,
          entry: entry
        }
        cadence = now + (cfg.dig("patrol", "poll_interval_sec") || 600).to_i
        @next_check_at[project] = cadence
        @post_reserve_at[project] = cadence
        persist_gates(entry, now: now)
        candidate.reject { |key, _| key == :entry }
      rescue StandardError
        @pending.delete(project)
        raise
      end

      def complete(project:, exit_code:, envelope: nil, now: Time.now)
        pending = @pending.delete(project)
        if exit_code == Hive::ExitCodes::SUCCESS
          @failures.delete(project)
        else
          count = @failures.dig(project, :count).to_i + 1
          interval = FAILURE_BACKOFF_SCHEDULE[
            [ count - 1, FAILURE_BACKOFF_SCHEDULE.size - 1 ].min
          ]
          exhaustions = patrol_resource_exhaustions(envelope)
          interval = Hive::Patrol::LaunchBudget.resource_exhaustion_backoff_sec(
            exhaustions.map { |item| item.fetch("reason") },
            now: now,
            fallback: interval
          )
          @failures[project] = { count: count, next_eligible_at: now + interval }
        end
        entry = pending && pending[:entry]
        persist_gates(entry, now: now) if entry
      end

      # Release process-local admission when the dispatcher gates a candidate
      # before spawning it.
      def cancel(project:)
        pending = @pending.delete(project)
        @next_check_at.delete(project)
        entry = pending && pending[:entry]
        persist_gates(entry, now: Time.now) if entry
      end

      def pending?(project)
        @pending.key?(project)
      end

      private

      def observe(project, state, reason, deadline = nil, trigger: nil)
        @observations[project.to_s] = {
          state: state, reason: reason.to_s, deadline: deadline, trigger: trigger
        }
      end

      def readiness_item(project, observation)
        return [] if observation.fetch(:state) == :disabled

        state = observation.fetch(:state)
        deadline = observation[:deadline]
        condition = if state == :runnable_now
          nil
        elsif deadline
          {
            "kind" => "time_due", "project" => project,
            "deadline" => deadline.utc.iso8601(6)
          }
        elsif observation[:trigger] == "new_commits"
          { "kind" => "task_changed", "project" => project }
        else
          { "kind" => "attempt_completed", "project" => project }
        end
        [
          {
            "bucket" => state.to_s,
            "id" => "patrol:scan", "component" => "patrol",
            "reason" => observation.fetch(:reason),
            "next_check_at" => deadline,
            "condition" => condition
          }
        ]
      end

      def load_gates(entry)
        project = entry.fetch("name")
        return if @loaded_gates[project]

        data = @schedule_state_factory.call(entry).read("patrol")
        @next_check_at[project] = parse_time(data["observation_check_at"])
        @post_reserve_at[project] = parse_time(data["post_reserve_at"])
        if data["failure_count"].to_i.positive?
          @failures[project] = {
            count: data.fetch("failure_count").to_i,
            next_eligible_at: parse_time(data["failure_retry_at"])
          }
        end
        @loaded_gates[project] = true
      end

      def persist_gates(entry, now:)
        return unless entry

        project = entry.fetch("name")
        failure = @failures[project]
        @schedule_state_factory.call(entry).update("patrol", now: now) do |state|
          state.merge(
            "observation_check_at" => iso_time(@next_check_at[project]),
            "post_reserve_at" => iso_time(@post_reserve_at[project]),
            "failure_count" => failure&.fetch(:count, 0).to_i,
            "failure_retry_at" => iso_time(failure && failure[:next_eligible_at])
          )
        end
      end

      def iso_time(value) = value&.utc&.iso8601(6)

      def blocked_until(project, now)
        deadlines = [
          @post_reserve_at[project], @failures.dig(project, :next_eligible_at)
        ].compact.select { |deadline| deadline > now }
        deadlines.max
      end

      # Candidate rows are hints captured before the dispatcher regains
      # control. Re-resolve the registration so a removed/replaced project
      # cannot launch against its former path or state home.
      def current_entry_for(project, observed)
        current = Array(@registry.call).find do |entry|
          entry.fetch("name") == project
        end
        return unless current
        return unless same_registration?(observed, current)

        current
      end

      def same_registration?(observed, current)
        %w[project_id registration_id].all? do |key|
          observed[key].to_s == current[key].to_s
        end && %w[path hive_state_path].all? do |key|
          File.expand_path(observed.fetch(key)) ==
            File.expand_path(current.fetch(key))
        end
      rescue KeyError, TypeError
        false
      end

      def launch_capacity_available?(entry, cfg, now)
        budget = allowance_budget(entry, now, cfg: cfg)
        return true if budget.remaining_launches.positive?

        exhaustion = budget.resource_exhaustion || {}
        retry_at = parse_retry_time(exhaustion["retry_at"] || exhaustion[:retry_at])
        deadline = retry_at || begin
          reason = exhaustion["reason"] || exhaustion[:reason]
          delay = Hive::Patrol::LaunchBudget.resource_exhaustion_backoff_sec(
            [ reason ].compact, now: now, fallback: FAILURE_BACKOFF_SCHEDULE.first
          )
          now + delay
        end
        @next_check_at[entry.fetch("name")] = deadline
        false
      end

      def patrol_resource_exhaustions(envelope)
        return [] unless envelope.is_a?(Hash)

        errors = envelope["review_errors"] || envelope[:review_errors]
        Array(errors).filter_map do |error|
          next unless error.is_a?(Hash)

          details = error["details"] || error[:details]
          exhaustion = details.is_a?(Hash) &&
                       (details["resource_exhaustion"] || details[:resource_exhaustion])
          next unless exhaustion.is_a?(Hash)

          exhaustion.transform_keys(&:to_s).tap do |item|
            item["reason"] = item.fetch("reason", "").to_s
          end
        end
      end

      def allowance_budget(entry, now, cfg: nil)
        Hive::Patrol::LaunchBudget.new(
          entry.fetch("path"), cfg: cfg || @config_loader.call(entry.fetch("path")),
          project_id: entry.fetch("project_id"),
          project_name: entry.fetch("name"), engine: :ordinary,
          database: @database,
          clock: -> { now }
        )
      end

      def parse_retry_time(value)
        return value.utc if value.respond_to?(:utc)
        return nil if value.to_s.empty?

        Time.iso8601(value.to_s).utc
      rescue ArgumentError
        nil
      end

      def backed_off?(project, now)
        deadline = @failures.dig(project, :next_eligible_at)
        deadline && now < deadline
      end

      def throttled?(project, now)
        return false if @failures.key?(project)

        deadline = @next_check_at[project]
        deadline && now < deadline
      end

      def schedule_selection_input(entry, cfg, patrol, now, state:)
        trigger = patrol.fetch("trigger", "continuous").to_s
        unless patrol["enabled"] == true &&
               Hive::Workflows.coding_id?(cfg["default_workflow"])
          return Hive::Patrol::DecisionProjection.schedule_input(
            enabled: false,
            trigger: trigger,
            timer_due: nil,
            branch_changed: nil
          )
        end

        branch_changed = if %w[continuous new_commits].include?(trigger)
          default_branch_changed?(entry, cfg, state)
        end
        timer_due = if %w[continuous timer].include?(trigger)
          timer_due?(state, patrol, now)
        end
        Hive::Patrol::DecisionProjection.schedule_input(
          enabled: true,
          trigger: trigger,
          timer_due: timer_due,
          branch_changed: branch_changed
        )
      end

      def next_schedule_check_at(state, patrol, selection_input, now)
        interval = patrol.fetch("poll_interval_sec", 600).to_i
        return now + interval unless %w[timer continuous].include?(
          selection_input.fetch("trigger")
        )
        return now + interval unless selection_input["timer_due"] == false

        last_run_at = parse_time(state["last_run_at"])
        last_run_at ? last_run_at + interval : now + interval
      end

      def timer_due?(state, patrol, now)
        last = parse_time(state["last_run_at"])
        last.nil? || (now - last) >= patrol.fetch("poll_interval_sec", 600)
      end

      def default_branch_changed?(entry, cfg, state)
        branch = @git.default_branch(entry.fetch("path"), cfg: cfg)
        current = @git.rev_parse(entry.fetch("path"), branch)
        current != state["last_scanned_sha"]
      end

      def read_state(entry)
        path = File.join(
          entry.fetch("hive_state_path"), "patrol", "state.json"
        )
        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end

      def parse_time(value)
        value && Time.parse(value)
      rescue ArgumentError
        nil
      end

      def dispatch_for(entry)
        project = entry.fetch("name")
        {
          project: project,
          slug: PATROL_SLUG,
          stage: PATROL_STAGE,
          command: "hive patrol #{Shellwords.escape(project)} --json",
          patrol_kind: :ordinary,
          state_file_mtime: nil,
          state_file_path: nil,
          hive_state_path: entry["hive_state_path"],
          entry: entry
        }
      end

      def state_store(entry)
        @state_store_factory.call(entry)
      end
    end
  end
end
