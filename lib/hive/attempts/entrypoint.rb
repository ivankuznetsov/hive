require "securerandom"
require "hive/attempts/client"
require "hive/attempts/configured_dispatcher"
require "hive/attempts/finalization_maintenance"
require "hive/runtime_control_plane/dispatch_repository"
require "hive/daemon/recovery_coordinator"

module Hive
  module Attempts
    # Internal foreground adapter behind Attempts::API. It performs durable
    # admission and optionally attaches a read-only client; the existing
    # command implementation runs later inside the wrapper.
    class Entrypoint
      def initialize(store: nil, dispatcher: nil, client: nil,
                     maintenance: nil, recovery_coordinator: nil, state_home: nil)
        @store = store
        @dispatcher = dispatcher
        @client = client
        @maintenance = maintenance
        @recovery_coordinator = recovery_coordinator
        @state_home = state_home
      end

      def dispatch(task:, intended_stage:, argv:, request_id: SecureRandom.uuid,
                   provider: nil, interactive: true, now: Time.now.utc)
        store = @store ||= Repository.open_default
        @maintenance ||= FinalizationMaintenance.runtime(store: store)
        run_opportunistic_maintenance(@maintenance, now: now)
        dispatcher = @dispatcher ||= ConfiguredDispatcher.new(store: store)
        project = project_name_for(task)
        result = dispatcher.dispatch(
          task: task,
          project: project,
          intended_stage: intended_stage,
          argv: argv,
          request_id: request_id,
          provider: provider,
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

      # Storage upkeep must never become an admission outage. The concrete
      # maintenance service records degraded health before raising, then the
      # next due run retries while this request continues to dispatch.
      def run_opportunistic_maintenance(maintenance, now:)
        maintenance&.run_if_due(now: now)
      rescue StandardError
        nil
      end

      def project_name_for(task)
        project = Hive::Config.project_for_path(task.project_root)
        project ? project.fetch("name") : task.project_name
      end
    end
  end
end
