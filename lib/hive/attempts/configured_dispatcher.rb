require "hive/config"
require "hive/task_resolver"
require "hive/attempts/detached_launcher"
require "hive/attempts/dispatcher"
require "hive/attempts/launch_policy"

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
                     launcher_class: DetachedLauncher,
                     dispatcher_class: Dispatcher,
                     worker_release_io: nil)
        @store = store
        @config_loader = config_loader
        @daemon_config_loader = daemon_config_loader
        @launcher_class = launcher_class
        @dispatcher_class = dispatcher_class
        @worker_release_io = worker_release_io
        @worker_release_io_claimed = false
        @worker_release_io_lock = Mutex.new
      end

      def dispatch_request(request, interactive: false, now: Time.now.utc)
        task = Hive::TaskResolver.new(
          request.slug, project_filter: request.project
        ).resolve
        dispatcher_for(task, argv: request.argv).dispatch_request(
          request, interactive: interactive, now: now
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
        worker_release_io =
          claim_worker_release_io
        launcher_options = {
          store: @store,
          heartbeat_sec: cfg.fetch("attempt_heartbeat_sec"),
          stale_sec: cfg.fetch("attempt_stale_sec"),
          first_heartbeat_timeout_sec: cfg.fetch("attempt_first_heartbeat_timeout_sec"),
          timeout_sec: LaunchPolicy.timeout_sec(daemon: daemon, argv: argv),
          kill_grace_sec: LaunchPolicy.kill_grace_sec(daemon: daemon)
        }
        if worker_release_io
          launcher_options[:worker_release_io] =
            worker_release_io
        end
        launcher = @launcher_class.new(**launcher_options)
        @dispatcher_class.new(
          store: @store,
          launcher: launcher,
          limits: LaunchPolicy.limits(daemon: daemon),
          launch_timeout_sec: cfg.fetch("attempt_launch_timeout_sec"),
          task_resolver: task_resolver
        )
      end

      def claim_worker_release_io
        return nil unless @worker_release_io

        @worker_release_io_lock.synchronize do
          if @worker_release_io_claimed
            raise StoreError,
                  "worker release gate has already been consumed"
          end
          unless
            @worker_release_io.respond_to?(:closed?) &&
              !@worker_release_io.closed?
            raise StoreError,
                  "worker release gate is unavailable"
          end

          @worker_release_io_claimed = true
          @worker_release_io
        end
      end
    end
  end
end
