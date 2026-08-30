require "hive/config"
require "hive/task_resolver"
require "hive/attempts/detached_launcher"
require "hive/attempts/dispatcher"
require "hive/attempts/launch_policy"
require "hive/provider_routing"

module Hive
  module Attempts
    # Internal daemon adapter behind Attempts::API. It resolves attempt timers,
    # execution timeout, and project-specific lease timers plus global
    # execution/capacity policy for every admission. A long-lived daemon
    # therefore applies config reloads to fresh attempts without replacing the
    # adapter or mutating running wrappers.
    class ConfiguredDispatcher
      def initialize(store:, config_loader: Hive::Config.method(:load),
                     daemon_config_loader: Hive::Config.method(:load_global_daemon),
                     launcher_class: DetachedLauncher, dispatcher_class: Dispatcher)
        @store = store
        @config_loader = config_loader
        @daemon_config_loader = daemon_config_loader
        @launcher_class = launcher_class
        @dispatcher_class = dispatcher_class
      end

      def dispatch_request(request, interactive: false, now: Time.now.utc,
                           admission_view: nil)
        task = Hive::TaskResolver.new(
          request.slug, project_filter: request.project
        ).resolve
        dispatcher_for(task, argv: request.argv).dispatch_request(
          request, interactive: interactive, now: now,
          admission_view: admission_view
        )
      end

      def dispatch_successor(task:, **attributes)
        dispatcher_for(task, argv: attributes.fetch(:argv)).dispatch_successor(
          task: task, **attributes
        )
      end

      def dispatch_module_hook(project_root:, argv:, **attributes)
        dispatcher_for_project(project_root, argv: argv).dispatch_module_hook(
          argv: argv, **attributes
        )
      end

      private

      def dispatcher_for(task, argv:)
        dispatcher_for_project(
          task.project_root, argv: argv,
          task_resolver: ->(_request) { task }
        )
      end

      def dispatcher_for_project(project_root, argv:, task_resolver: nil)
        cfg = @config_loader.call(project_root)
        daemon = @daemon_config_loader.call
        launcher = @launcher_class.new(
          store: @store,
          heartbeat_sec: cfg.fetch("attempt_heartbeat_sec"),
          stale_sec: cfg.fetch("attempt_stale_sec"),
          first_heartbeat_timeout_sec: cfg.fetch("attempt_first_heartbeat_timeout_sec"),
          timeout_sec: LaunchPolicy.timeout_sec(daemon: daemon, argv: argv),
          kill_grace_sec: LaunchPolicy.kill_grace_sec(daemon: daemon)
        )
        @dispatcher_class.new(
          store: @store,
          launcher: launcher,
          limits: LaunchPolicy.limits(daemon: daemon),
          transient_retry_backoff_sec: daemon.fetch("transient_retry_backoff_sec"),
          launch_timeout_sec: cfg.fetch("attempt_launch_timeout_sec"),
          task_resolver: task_resolver,
          routing_policy_resolver: lambda do |_task, intended_stage|
            if controller_only_command?(argv)
              next Hive::ProviderRouting::Policy.legacy(
                stage: routing_stage_name(intended_stage)
              )
            end

            Hive::ProviderRouting::Configuration.from(
              cfg: cfg,
              stage_name: routing_stage_name(intended_stage)
            ).policy
          end
        )
      end

      # The digest-bound rework command only moves controller-owned state and
      # records an authorization receipt. It launches no model, so provider
      # health and route capacity must not be prerequisites for admitting it.
      def controller_only_command?(argv)
        Array(argv).first(3) == %w[hive evidence rework]
      end

      def routing_stage_name(intended_stage)
        intended_stage.to_s.sub(/\A\d+-/, "").tr("-", "_")
      end
    end
  end
end
