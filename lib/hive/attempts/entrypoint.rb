require "securerandom"
require "hive/attempts/client"
require "hive/attempts/detached_launcher"
require "hive/attempts/dispatcher"
require "hive/attempts/launch_policy"

module Hive
  module Attempts
    # Foreground facade shared by CLI commands and local request producers.
    # It performs durable admission and optionally attaches a read-only client;
    # the existing command implementation runs later inside the wrapper.
    class Entrypoint
      def initialize(store: nil, dispatcher: nil, client: nil,
                     config_loader: Hive::Config.method(:load),
                     daemon_config_loader: Hive::Config.method(:load_global_daemon))
        @store = store
        @dispatcher = dispatcher
        @client = client
        @config_loader = config_loader
        @daemon_config_loader = daemon_config_loader
      end

      def dispatch(task:, intended_stage:, argv:, request_id: SecureRandom.uuid,
                   provider: nil, interactive: true, now: Time.now.utc)
        cfg = @config_loader.call(task.project_root)
        store = @store || Store.new
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
          interactive: interactive,
          now: now
        )
        if result.status == :deferred
          raise Hive::ConcurrentRunError,
                "durable attempt deferred for #{task.slug}: #{result.reason}"
        end
        return result unless interactive

        attached = (@client || Client.new(store: store)).attach(result.attempt.attempt_id)
        attached
      end

      private

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
    end
  end
end
