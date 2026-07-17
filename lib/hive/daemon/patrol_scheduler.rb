require "json"
require "open3"
require "shellwords"
require "time"
require "hive/config"
require "hive/git_ops"
require "hive/daemon/pr_merge_watcher"

module Hive
  module Daemon
    # Slow-cadence collaborator that decides which registered projects
    # should receive one `hive patrol PROJECT --json` scan cycle. It only
    # returns dispatch hashes; Dispatcher still owns daemon.enabled,
    # legacy-layout, dry-run, and concurrency gates before spawning.
    class PatrolScheduler
      PATROL_STAGE = "patrol".freeze
      PATROL_SLUG = "patrol".freeze

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
                     git: GitHelper.new)
        @registry = registry
        @config_loader = config_loader
        @git = git
        @pending = {}
        @failures = {}
        @next_check_at = {}
      end

      def tick(now: Time.now)
        candidates(now: now).filter_map { |candidate| reserve(candidate, now: now) }
      end

      # Side-effect-free with respect to dispatch ownership: callers may
      # compare ordinary and architecture work without consuming a patrol
      # turn (`@pending` is touched only by reserve/complete/cancel).
      # Due-check throttles are NOT deferred, though: every project this
      # scan evaluates commits its `@next_check_at` window at evaluation
      # time — disabled, not-yet-due, and due candidates alike — and
      # `reserve` never touches the throttle. So a due candidate the
      # arbiter passes over is re-evaluated only after a full poll window,
      # and a second `candidates` call within one tick yields no work.
      def candidates(now: Time.now)
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
          # Throttle every project we evaluate, including opted-out ones:
          # each branch below commits `@next_check_at` once the project's
          # config has been loaded. Otherwise a disabled project would
          # reload its full config on every ~30s tick just to rediscover
          # patrol.enabled: false. A project that flips to enabled
          # mid-interval is picked up on its next poll window.
          unless patrol["enabled"] == true
            @next_check_at[project] = now + patrol.fetch("poll_interval_sec", 600).to_i
            next
          end
          unless due?(entry, cfg, patrol, now)
            @next_check_at[project] = now + patrol.fetch("poll_interval_sec", 600).to_i
            next
          end

          @next_check_at[project] = now + patrol.fetch("poll_interval_sec", 600).to_i
          dispatches << dispatch_for(entry, patrol: patrol)
        rescue Hive::ConfigError, Hive::GitError, KeyError
          next
        end
        dispatches
      end

      def reserve(candidate, now: Time.now)
        project = candidate.fetch(:project)
        return nil if pending?(project)

        @pending[project] = { started_at: now }
        public_dispatch(candidate)
      end

      def complete(project:, exit_code:, now: Time.now)
        @pending.delete(project)
        if exit_code.to_i.zero?
          @failures.delete(project)
        else
          count = @failures.dig(project, :count).to_i + 1
          interval = PrMergeWatcher::GH_BACKOFF_SCHEDULE[
            [ count - 1, PrMergeWatcher::GH_BACKOFF_SCHEDULE.size - 1 ].min
          ]
          @failures[project] = { count: count, next_eligible_at: now + interval }
        end
      end

      # Legacy `tick`-path escape hatch. In that mode (no arbiter) `tick`
      # reserves — marking `@pending` — before the Dispatcher applies its
      # gates (daemon-disabled, legacy layout, concurrency cap), so a
      # gated dispatch must release the marker here or the project would
      # stay pending until daemon restart: the gated paths never reach
      # `complete`, the only other thing that clears `@pending`. In
      # always-on arbiter mode the Dispatcher calls `reserve` only AFTER
      # those gates pass, so nothing is pending when they fire and its
      # pre-reserve `cancel` calls are no-ops there. No failure is
      # recorded — the scan never ran, so there is nothing to back off
      # from. Genuine spawn *errors* go through `complete` with a
      # non-zero exit instead.
      def cancel(project:)
        @pending.delete(project)
      end

      def pending?(project)
        @pending.key?(project)
      end

      private

      def backed_off?(project, now)
        deadline = @failures.dig(project, :next_eligible_at)
        deadline && now < deadline
      end

      def throttled?(project, now)
        return false if @failures.key?(project)

        deadline = @next_check_at[project]
        deadline && now < deadline
      end

      def due?(entry, cfg, patrol, now)
        state = read_state(entry.fetch("path"))
        case patrol.fetch("trigger", "continuous")
        when "timer"
          timer_due?(state, patrol, now)
        when "continuous"
          default_branch_changed?(entry, cfg, state) || timer_due?(state, patrol, now)
        else
          default_branch_changed?(entry, cfg, state)
        end
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

      def read_state(project_root)
        path = File.join(project_root, ".hive-state", "patrol", "state.json")
        return {} unless File.exist?(path)

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

      def dispatch_for(entry, patrol: {})
        project = entry.fetch("name")
        {
          project: project,
          slug: PATROL_SLUG,
          stage: PATROL_STAGE,
          command: "hive patrol #{Shellwords.escape(project)} --json",
          patrol_kind: :ordinary,
          state_file_mtime: nil,
          state_file_path: nil,
          hive_state_path: entry["hive_state_path"]
        }
      end

      def public_dispatch(candidate)
        candidate.reject { |key, _value| key == :patrol_kind }
      end
    end
  end
end
