require "securerandom"
require "hive/attempts/client"
require "hive/attempts/detached_launcher"
require "hive/attempts/dispatcher"
require "hive/attempts/launch_policy"
require "hive/attempts/finalization_maintenance"
require "hive/provider_routing"

module Hive
  module Attempts
    # Internal foreground adapter behind Attempts::API. It performs durable
    # admission and optionally attaches a read-only client; the existing
    # command implementation runs later inside the wrapper.
    class Entrypoint
      def initialize(store: nil, dispatcher: nil, client: nil,
                     maintenance: nil,
                     config_loader: Hive::Config.method(:load),
                     daemon_config_loader: Hive::Config.method(:load_global_daemon))
        @store = store
        @dispatcher = dispatcher
        @client = client
        @maintenance = maintenance
        @config_loader = config_loader
        @daemon_config_loader = daemon_config_loader
      end

      def dispatch(task:, intended_stage:, argv:, request_id: SecureRandom.uuid,
                   provider: nil, interactive: true, now: Time.now.utc)
        cfg = @config_loader.call(task.project_root)
        store = @store || Store.new
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
        return result unless interactive && result.attempt

        attached = (@client || Client.new(store: store)).attach(result.attempt.attempt_id)
        attached
      end

      private

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
