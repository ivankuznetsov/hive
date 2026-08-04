require "securerandom"
require "hive/attempts/contracts"

module Hive
  module Attempts
    autoload :ConfiguredDispatcher, "hive/attempts/configured_dispatcher"
    autoload :Entrypoint, "hive/attempts/entrypoint"
    autoload :Store, "hive/attempts/store"

    # Stable consumer-facing boundary for durable attempt admission.
    #
    # Hive remains the primary consumer. Entrypoint, ConfiguredDispatcher,
    # launchers, and stores are implementation collaborators behind this API.
    class API
      def initialize(store: nil, foreground: nil, daemon: nil)
        @store = store
        @foreground = foreground
        @daemon = daemon
      end

      def dispatch(task:, intended_stage:, argv:, request_id: SecureRandom.uuid,
                   provider: nil, interactive: true, now: Time.now.utc)
        foreground.dispatch(
          task: task, intended_stage: intended_stage, argv: argv,
          request_id: request_id, provider: provider,
          interactive: interactive, now: now
        )
      end

      def dispatch_request(request, interactive: false, now: Time.now.utc)
        daemon.dispatch_request(request, interactive: interactive, now: now)
      end

      def dispatch_successor(predecessor:, task:, project:, argv:, request_id:,
                             provider:, inherited_outputs: nil, retry_charge: nil,
                             interactive: false, now: Time.now.utc)
        daemon.dispatch_successor(
          predecessor: predecessor, task: task, project: project, argv: argv,
          request_id: request_id, provider: provider,
          inherited_outputs: inherited_outputs, retry_charge: retry_charge,
          interactive: interactive, now: now
        )
      end

      def dispatch_module_hook(project_root:, argv:, **attributes)
        daemon.dispatch_module_hook(
          project_root: project_root, argv: argv, **attributes
        )
      end

      private

      def foreground
        @foreground ||= Entrypoint.new(store: store)
      end

      def daemon
        @daemon ||= ConfiguredDispatcher.new(store: store)
      end

      def store
        @store ||= Store.new
      end
    end
  end
end
