require "json"
require "open3"
require "shellwords"
require "time"
require "hive/config"
require "hive/git_ops"
require "hive/patrol/decision_projection"
require "hive/patrol/launch_budget"
require "hive/patrol/state_store"
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
        @pending = {}
        @failures = {}
        @next_check_at = {}
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
      def candidates(now: Time.now)
        @events.clear
        dispatches = []
        @registry.call.each do |entry|
          project = entry.fetch("name")
          next if pending?(project)
          next if backed_off?(project, now)
          # Slow patrol cadence (U2): once a project has been evaluated,
          # don't re-run its per-project git/config checks until
          # poll_interval_sec has elapsed. Without this the `new_commits`
          # trigger shells out to `git rev-parse` on every daemon tick
          # (~30s) instead of the configured patrol interval. A project
          # with an outstanding failure is exempt so its backoff schedule
          # governs the retry rather than the slow poll.
          next if throttled?(project, now)

          cfg = @config_loader.call(entry.fetch("path"))
          patrol = cfg.fetch("patrol", {})
          unless Hive::Workflows.coding_id?(cfg["default_workflow"])
            @next_check_at[project] = now + patrol.fetch("poll_interval_sec", 600).to_i
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
            next
          end
          next unless launch_capacity_available?(entry, cfg, now)

          dispatches << dispatch_for(entry)
        rescue Hive::ConfigError, Hive::GitError, KeyError
          next
        end
        dispatches
      end

      def drain_events
        drained = @events.dup
        @events.clear
        drained
      end

      def reserve(candidate, now: Time.now)
        project = candidate.fetch(:project)
        entry = candidate.fetch(:entry)
        return nil if pending?(project)

        cfg = @config_loader.call(entry.fetch("path"))
        return nil unless Hive::Workflows.coding_id?(cfg["default_workflow"])
        cycle_admitted, = state_store(entry).try_with_cycle_admission { true }
        return nil unless cycle_admitted
        @pending[project] = {
          started_at: now,
          entry: entry
        }
        @next_check_at[project] = now +
          (cfg.dig("patrol", "poll_interval_sec") || 600).to_i
        candidate.reject { |key, _| key == :entry }
      rescue StandardError
        @pending.delete(project)
        raise
      end

      def complete(project:, exit_code:, envelope: nil, now: Time.now)
        @pending.delete(project)
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
      end

      # Release process-local admission when the dispatcher gates a candidate
      # before spawning it.
      def cancel(project:)
        @pending.delete(project)
        @next_check_at.delete(project)
      end

      def pending?(project)
        @pending.key?(project)
      end

      private

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
