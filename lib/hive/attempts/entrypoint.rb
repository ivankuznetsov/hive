require "securerandom"
require "hive/attempts/client"
require "hive/attempts/detached_launcher"
require "hive/attempts/dispatcher"
require "hive/attempts/launch_policy"
require "hive/attempts/finalization_maintenance"
require "hive/runtime_control_plane/dispatch_repository"
require "hive/daemon/recovery_coordinator"
require "hive/provider_routing"

module Hive
  module Attempts
    # Internal foreground adapter behind Attempts::API. It performs durable
    # admission and optionally attaches a read-only client; the existing
    # command implementation runs later inside the wrapper.
    class Entrypoint
      def initialize(store: nil, dispatcher: nil, client: nil,
                     maintenance: nil, recovery_coordinator: nil, state_home: nil,
                     config_loader: Hive::Config.method(:load),
                     daemon_config_loader: Hive::Config.method(:load_global_daemon))
        @store = store
        @dispatcher = dispatcher
        @client = client
        @maintenance = maintenance
        @recovery_coordinator = recovery_coordinator
        @state_home = state_home
        @config_loader = config_loader
        @daemon_config_loader = daemon_config_loader
      end

      def dispatch(task:, intended_stage:, argv:, request_id: SecureRandom.uuid,
                   provider: nil, interactive: true, now: Time.now.utc)
        cfg = @config_loader.call(task.project_root)
        store = @store || Repository.new
        maintenance = @maintenance
        maintenance ||= foreground_maintenance(store) unless @store
        run_opportunistic_maintenance(maintenance, now: now)
        dispatcher = @dispatcher || build_dispatcher(
          store, cfg, @daemon_config_loader.call, argv
        )
        result = dispatcher.dispatch(
          task: task,
          project: project_name_for(task),
          intended_stage: intended_stage,
          argv: argv,
          request_id: request_id,
          provider: provider || provider_for(cfg, intended_stage),
          routing_policy: routing_policy_for(cfg, intended_stage),
          interactive: interactive,
          now: now
        )
        if result.status == :deferred
          raise Hive::ConcurrentRunError,
                "durable attempt deferred for #{task.slug}: #{result.reason}"
        end
        if result.status == :no_route
          receipt = request_admission_recovery(
            result: result,
            task: task,
            argv: argv,
            request_id: request_id,
            store: store,
            now: now
          )
          if interactive
            raise Hive::ConcurrentRunError,
                  "provider route unavailable for #{task.slug}: #{receipt.human_summary}"
          end
          return result
        end
        return result unless interactive && result.attempt

        attached = (@client || Client.new(store: store)).attach(result.attempt.attempt_id)
        attached
      end

      private

      def request_admission_recovery(result:, task:, argv:, request_id:, store:, now:)
        coordinator = @recovery_coordinator || Hive::Daemon::RecoveryCoordinator.new(
          state_home: @state_home || state_home_for(store),
          dispatch_repository: Hive::RuntimeControlPlane::DispatchRepository.new(
            database: store.database
          )
        )
        request = Hive::RuntimeControlPlane::DispatchRepository::Request.new(
          request_id: request_id.to_s,
          project: project_name_for(task),
          slug: task.slug,
          argv: argv,
          requestor: "cli",
          predecessor_attempt_id: nil,
          inherited_outputs: [], chat_id: nil, update_id: nil, trigger: "recovery",
          task_generation: nil, task_id: task.id, expected_stage: task.stage_name,
          expected_marker_name: nil, expected_marker_id: nil, recovery: nil,
          schema_version: Hive::RuntimeControlPlane::DispatchRepository::SCHEMA_VERSION,
          state: "queued", revision: 0, created_at: now
        )
        coordinator.request_admission_failure(
          request: request,
          decision: result.decision,
          now: now
        )
      end

      def state_home_for(store)
        File.dirname(File.dirname(store.root))
      rescue NoMethodError
        Hive::Paths.state_home
      end

      # Storage upkeep must never become an admission outage. The concrete
      # maintenance service records degraded health before raising, then the
      # next due run retries while this request continues to dispatch.
      def run_opportunistic_maintenance(maintenance, now:)
        maintenance&.run_if_due(now: now)
      rescue StandardError
        nil
      end

      def foreground_maintenance(store)
        @maintenance = FinalizationMaintenance.runtime(store: store)
      end

      def build_dispatcher(store, cfg, daemon, argv)
        launcher = DetachedLauncher.new(
          store: store,
          heartbeat_sec: cfg.fetch("attempt_heartbeat_sec"),
          stale_sec: cfg.fetch("attempt_stale_sec"),
          first_heartbeat_timeout_sec: cfg.fetch("attempt_first_heartbeat_timeout_sec"),
          timeout_sec: LaunchPolicy.timeout_sec(daemon: daemon, argv: argv),
          kill_grace_sec: LaunchPolicy.kill_grace_sec(daemon: daemon)
        )
        Dispatcher.new(
          store: store,
          launcher: launcher,
          launch_timeout_sec: cfg.fetch("attempt_launch_timeout_sec"),
          limits: LaunchPolicy.limits(daemon: daemon)
        )
      end

      def project_name_for(task)
        project = Hive::Config.registered_projects.find do |candidate|
          File.expand_path(candidate["path"]) == File.expand_path(task.project_root)
        end
        project ? project.fetch("name") : task.project_name
      end

      def provider_for(cfg, intended_stage)
        stage = intended_stage.to_s.sub(/\A\d+-/, "").tr("-", "_")
        cfg.dig(stage, "agent") || Hive::Config::DEFAULTS.dig(stage, "agent") || "claude"
      end

      def routing_policy_for(cfg, intended_stage)
        stage = intended_stage.to_s.sub(/\A\d+-/, "").tr("-", "_")
        Hive::ProviderRouting::Configuration.from(
          cfg: cfg,
          stage_name: stage
        ).policy
      end
    end
  end
end
