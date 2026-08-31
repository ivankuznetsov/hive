require "securerandom"
require "hive/attempts/contracts"

module Hive
  module Attempts
    autoload :ConfiguredDispatcher, "hive/attempts/configured_dispatcher"
    autoload :Entrypoint, "hive/attempts/entrypoint"
    autoload :Repository, "hive/attempts/repository"

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
                   provider: nil, interactive: true, now: Time.now.utc,
                   proposal_admission: nil)
        foreground.dispatch(
          task: task, intended_stage: intended_stage, argv: argv,
          request_id: request_id, provider: provider,
          interactive: interactive, now: now, proposal_admission: proposal_admission
        )
      end

      def dispatch_request(request, interactive: false, now: Time.now.utc,
                           admission_view: nil, replay_semantic_terminal: false)
        daemon.dispatch_request(
          request, interactive: interactive, now: now,
          admission_view: admission_view,
          replay_semantic_terminal: replay_semantic_terminal
        )
      end

      def dispatch_recovery(source_attempt:, task:, project:, argv:, request_id:,
                            provider:, inherited_outputs: nil, retry_charge: nil,
                            interactive: false, now: Time.now.utc,
                            admission_view: nil)
        daemon.dispatch_recovery(
          source_attempt: source_attempt, task: task, project: project, argv: argv,
          request_id: request_id, provider: provider,
          inherited_outputs: inherited_outputs, retry_charge: retry_charge,
          interactive: interactive, now: now, admission_view: admission_view
        )
      end

      def dispatch_module_hook(project_root:, generation:, subject:, argv:,
                               request_id:, provider:, interactive: false,
                               retry_charge: 0,
                               now: Time.now.utc)
        daemon.dispatch_module_hook(
          project_root: project_root, generation: generation, subject: subject,
          argv: argv, request_id: request_id, provider: provider,
          interactive: interactive,
          retry_charge: retry_charge, now: now
        )
      end

      def correlated_log_reader
        require "hive/task_workspace/correlated_log"
        Hive::TaskWorkspace::CorrelatedLog.new(
          root: store.root,
          reference_resolver: ->(reference) { store.sealed_payload_reference(reference) }
        )
      end

      # Read-only durable bindings for consumers that must correlate a task
      # projection with the exact attempt admitted by this subsystem. Keeping
      # these reads on the facade prevents consumers from constructing the
      # internal Repository while preserving TaskJournal's strict validation seam.
      def fetch(attempt_id)
        store.fetch(attempt_id)
      end

      def fetch_projection_binding(attempt_id)
        store.fetch_projection_binding(attempt_id)
      end

      private

      def foreground
        @foreground ||= Entrypoint.new(store: store)
      end

      def daemon
        @daemon ||= ConfiguredDispatcher.new(store: store)
      end

      def store
        @store ||= Repository.open_default
      end
    end
  end
end
