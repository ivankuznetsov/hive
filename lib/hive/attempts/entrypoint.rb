require "securerandom"
require "hive/attempts/client"
require "hive/attempts/configured_dispatcher"
require "hive/runtime_control_plane/dispatch_repository"
require "hive/daemon/recovery_coordinator"
require "hive/proposals/evaluator_authority"
require "hive/proposals/source_event"

module Hive
  module Attempts
    # Internal foreground adapter behind Attempts::API. It performs durable
    # admission and optionally attaches a read-only client; the existing
    # command implementation runs later inside the wrapper.
    class Entrypoint
      def initialize(store: nil, dispatcher: nil, client: nil,
                     recovery_coordinator: nil, state_home: nil,
                     config_loader: Hive::Config.method(:load))
        @store = store
        @dispatcher = dispatcher
        @client = client
        @recovery_coordinator = recovery_coordinator
        @state_home = state_home
        @config_loader = config_loader
      end

      def dispatch(task:, intended_stage:, argv:, request_id: SecureRandom.uuid,
                   provider: nil, interactive: true, now: Time.now.utc,
                   proposal_admission: nil)
        store = @store ||= Repository.open_default
        dispatcher = @dispatcher ||= ConfiguredDispatcher.new(
          store: store, config_loader: @config_loader
        )
        project = project_name_for(task)
        subject = proposal_attempt_subject(
          task: task, intended_stage: intended_stage, provider: provider,
          admission: proposal_admission
        )
        result = dispatcher.dispatch(
          task: task,
          project: project,
          intended_stage: intended_stage,
          argv: argv,
          request_id: request_id,
          provider: provider,
          subject: subject,
          interactive: interactive,
          now: now
        )
        if result.status == :deferred
          raise Hive::ConcurrentRunError,
                "durable attempt deferred for #{task.slug}: #{result.reason}"
        end
        if result.status == :no_route
          receipt = request_admission_recovery(
            result: result, task: task, project: project,
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

      def proposal_attempt_subject(task:, intended_stage:, provider:, admission:)
        return nil unless admission

        data = Hive::Proposals.closed_hash!(
          admission,
          required: %w[subject actor evaluator_identity agent_profile],
          label: "proposal attempt admission"
        )
        cfg = @config_loader.call(task.project_root)
        authority = Hive::Proposals::EvaluatorAuthority.new(cfg)
        workflow = task.respond_to?(:workflow) ? task.workflow : nil
        workflow = workflow.id if workflow.respond_to?(:id)
        workflow = cfg.fetch("default_workflow") if workflow.to_s.empty?
        evaluator = if data["evaluator_identity"]
          authority.bind!(
            identity: data["evaluator_identity"], workflow: workflow,
            stage: intended_stage,
            agent_profile: data["agent_profile"] || provider_for(cfg, intended_stage, provider)
          )
        end
        binding = Hive::Proposals::SourceEvent.normalize_proposal_binding(
          "schema_version" => 1,
          "subject" => data.fetch("subject"), "actor" => data.fetch("actor"),
          "evaluator" => evaluator,
          "configuration_fingerprint" => authority.configuration_fingerprint,
          "policy" => cfg.dig("proposals", "evidence")
        )
        Hive::Attempts::Record.task_stage_subject(
          task_id: task.respond_to?(:id) ? task.id&.to_s : nil,
          task_slug: task.slug, intended_stage: intended_stage, proposal: binding
        )
      end

      def request_admission_recovery(result:, task:, project:, argv:, request_id:, store:, now:)
        coordinator = @recovery_coordinator || Hive::Daemon::RecoveryCoordinator.new(
          state_home: @state_home || state_home_for(store),
          dispatch_repository: Hive::RuntimeControlPlane::DispatchRepository.new(
            database: store.database
          )
        )
        request = Hive::RuntimeControlPlane::DispatchRepository::Request.new(
          request_id: request_id.to_s,
          project: project,
          slug: task.slug,
          argv: argv,
          requestor: "cli",
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

      def project_name_for(task)
        project = Hive::Config.project_for_path(task.project_root)
        project ? project.fetch("name") : task.project_name
      end

      def provider_for(cfg, intended_stage, provider)
        return provider if provider

        stage = intended_stage.to_s.sub(/\A\d+-/, "").tr("-", "_")
        cfg.dig(stage, "agent") || Hive::Config::DEFAULTS.dig(stage, "agent") || "claude"
      end
    end
  end
end
