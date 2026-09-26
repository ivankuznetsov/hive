require "hive/attempts/api"
require "hive/attempts/finalization_maintenance"
require "hive/attempts/lost_outcome"
require "hive/attempts/process_identity"
require "hive/attempts/reconciler"
require "hive/attempts/repository"
require "hive/conditions/attempt_observer"
require "hive/daemon/child_supervisor"
require "hive/daemon/concurrency_controller"
require "hive/daemon/dispatch_baselines"
require "hive/daemon/dispatcher"
require "hive/daemon/logger"
require "hive/daemon/patrol_fix_admission_scheduler"
require "hive/daemon/patrol_fix_runtime"
require "hive/daemon/pr_merge_watcher"
require "hive/daemon/refactor_patrol_scheduler"
require "hive/daemon/status_consumer"
require "hive/modules/daemon_runtime"
require "hive/one_shot/schedule_state"
require "hive/one_shot/project_liveness"

module Hive
  module OneShot
    class Runner
      class ScopedOwnership
        attr_reader :contentions

        def initialize(project)
          @project = project.to_s
          @contentions = {}
        end

        def refresh! = [ @project ]
        def owned?(project) = project.to_s == @project
        def owned_projects = [ @project ]
      end

      attr_reader :ran

      def self.build(entry:, hive_home: Hive::Paths.state_home, dry_run: false,
                     clock: -> { Time.now.utc })
        project = entry.fetch("name")
        daemon_cfg = Hive::Config.load_global_daemon
        config = { "daemon" => daemon_cfg }
        logger = Hive::Daemon::Logger.new(
          path: File.join(entry.fetch("hive_state_path"), "scheduler", "dispatch.log"),
          max_bytes: daemon_cfg.fetch("log_max_bytes"),
          max_files: daemon_cfg.fetch("log_max_files")
        )
        schedule_state = ->(_project) do
          Hive::OneShot::ScheduleState.new(state_root: entry.fetch("hive_state_path"))
        end
        controller = Hive::Daemon::ConcurrencyController.new(
          max_concurrent_runs: daemon_cfg.fetch("max_concurrent_runs"),
          max_concurrent_per_project: daemon_cfg.fetch("max_concurrent_per_project"),
          max_runs_per_day_per_project: daemon_cfg.fetch("max_runs_per_day_per_project"),
          max_concurrent_patrol_scans: daemon_cfg.fetch("max_concurrent_patrol_scans"),
          dispatch_state: Hive::Daemon::DispatchBaselines.new(
            path: File.join(hive_home, "daemon_dispatch_baselines.json"), logger: logger
          ),
          schedule_state_factory: schedule_state,
          persistence_scope_projects: [ project ]
        )
        supervisor = Hive::Daemon::ChildSupervisor.new(
          dry_run: dry_run,
          default_timeout_sec: daemon_cfg.fetch("child_timeout_sec"),
          verb_timeouts: daemon_cfg.fetch("child_verb_timeouts", {}),
          stage_timeouts: daemon_cfg.fetch("child_stage_timeouts", {}),
          kill_grace_sec: daemon_cfg.fetch("child_kill_grace_sec")
        )
        attempt_store = Hive::Attempts::Repository.open_default(state_home: hive_home)
        attempts_api = Hive::Attempts::API.new(store: attempt_store)
        identity = Hive::Attempts::ProcessIdentity.new
        observer = Hive::Conditions::AttemptObserver.new(store: attempt_store, logger: logger)
        maintenance = Hive::Attempts::FinalizationMaintenance.runtime(
          store: attempt_store, state_home: hive_home, logger: logger
        )
        reconciler = Hive::Attempts::Reconciler.new(
          store: attempt_store, process_identity: identity,
          condition_observer: observer, finalization_maintenance: maintenance, logger: logger
        )
        lost_store = Hive::Attempts::LostOutcomeTransition.new(store: attempt_store)
        patrol_fix = Hive::Daemon::PatrolFixRuntime.new(registry: -> { [ entry ] })
        patrol_fix_scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
          sources: -> { patrol_fix.sources },
          semantic_admission_factory: patrol_fix.method(:semantic_admission),
          task_materializer_factory: patrol_fix.method(:task_materializer),
          capacity_available: lambda do |source:, now:, **|
            controller.can_dispatch?(
              project: source.project, slug: "patrol-fix-admission", now: now
            ) == :ok
          end
        )
        dispatcher = Hive::Daemon::Dispatcher.new(
          config: config, controller: controller, supervisor: supervisor,
          status_consumer: Hive::Daemon::StatusConsumer.new, logger: logger,
          merge_watcher: Hive::Daemon::PrMergeWatcher.new(
            poll_interval_sec: daemon_cfg.fetch("pr_merge_poll_interval_sec"), dry_run: dry_run,
            schedule_state_factory: schedule_state
          ),
          refactor_patrol_scheduler: Hive::Daemon::RefactorPatrolScheduler.new(
            registry: -> { [ entry ] }, dry_run: dry_run
          ),
          patrol_fix_admission_scheduler: patrol_fix_scheduler,
          dry_run: dry_run, attempt_dispatcher: attempts_api,
          attempt_reconciler: reconciler, lost_outcome_store: lost_store,
          lost_outcome_processor: Hive::Attempts::LostOutcomeProcessor.new(
            store: attempt_store, outcome_store: lost_store, process_identity: identity
          ),
          module_runtime: Hive::Modules::DaemonRuntime.new(
            attempt_store: attempt_store, attempt_dispatcher: attempts_api,
            registry: -> { [ entry ] }
          ),
          project_ownership: ScopedOwnership.new(project), scope_projects: [ project ],
          project_liveness: Hive::OneShot::ProjectLiveness.new(
            entry: entry, state_home: hive_home, attempt_store: attempt_store
          ),
          dispatch_repository: Hive::RuntimeControlPlane::DispatchRepository.new(
            database: attempt_store.database
          ),
          dispatch_request_state_home: hive_home, clock: clock
        )
        new(dispatcher: dispatcher, project: project, dry_run: dry_run,
            logger: logger, clock: clock)
      end

      def initialize(dispatcher:, project:, dry_run: false, logger: nil,
                     clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) })
        @dispatcher = dispatcher
        @project = project
        @dry_run = dry_run
        @logger = logger
        @clock = clock
        @sleeper = sleeper
        @ran = []
      end

      def call
        result = if @dry_run
          @dispatcher.observe_one_shot(project: @project, now: @clock.call)
        else
          @dispatcher.run_one_shot(project: @project, now: @clock.call, sleeper: @sleeper)
        end
        @ran = result.fetch(:ran)
        result
      rescue StandardError, SignalException
        @ran = @dispatcher.one_shot_ran.dup
        raise
      end

      def close = @logger&.close
    end
  end
end
