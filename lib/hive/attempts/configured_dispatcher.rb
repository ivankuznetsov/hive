require "hive/config"
require "hive/task_resolver"
require "hive/attempts/detached_launcher"
require "hive/attempts/dispatcher"

module Hive
  module Attempts
    # Daemon adapter that resolves attempt timers from the task's project for
    # every admission. One long-lived daemon may serve projects with different
    # heartbeat and launch policies; a single default-configured launcher
    # silently ignored those project contracts.
    class ConfiguredDispatcher
      def initialize(store:, limits:, config_loader: Hive::Config.method(:load),
                     launcher_class: DetachedLauncher, dispatcher_class: Dispatcher)
        @store = store
        @limits = limits
        @config_loader = config_loader
        @launcher_class = launcher_class
        @dispatcher_class = dispatcher_class
      end

      def dispatch_request(request, interactive: false, now: Time.now.utc)
        task = Hive::TaskResolver.new(
          request.slug, project_filter: request.project
        ).resolve
        dispatcher_for(task).dispatch_request(request, interactive: interactive, now: now)
      end

      def dispatch_successor(task:, **attributes)
        dispatcher_for(task).dispatch_successor(task: task, **attributes)
      end

      private

      def dispatcher_for(task)
        cfg = @config_loader.call(task.project_root)
        launcher = @launcher_class.new(
          store: @store,
          heartbeat_sec: cfg.fetch("attempt_heartbeat_sec"),
          stale_sec: cfg.fetch("attempt_stale_sec"),
          first_heartbeat_timeout_sec: cfg.fetch("attempt_first_heartbeat_timeout_sec")
        )
        @dispatcher_class.new(
          store: @store,
          launcher: launcher,
          limits: @limits,
          launch_timeout_sec: cfg.fetch("attempt_launch_timeout_sec"),
          task_resolver: ->(_request) { task }
        )
      end
    end
  end
end
