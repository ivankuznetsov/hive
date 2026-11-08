require "hive/workflow_admission"
require "hive/remote/contract"
require "digest"
require "time"
require "shellwords"
require "hive/command_operation"
require "hive/command_receipt_pruner"
require "hive/commands/new"
require "hive/commands/answer"
require "hive/commands/approve"
require "hive/operational_action"
require "hive/bot/dispatch_request_writer"
require "hive/attempts/generation"
require "hive/recovery/retry_policy"
require "hive/remote/errors"

module Hive
  module Remote
    # A typed admission boundary. It accepts registered project/task objects,
    # never caller paths or argv. Long effects belong to the daemon after the
    # durable caller receipt and request have committed.
    class CommandService
      def initialize(store: Hive::CommandReceiptStore.new, repository: nil, clock: -> { Time.now.utc })
        @store = store
        @repository = repository || Hive::RuntimeControlPlane::DispatchRepository.new(database: store.database)
        @clock = clock
      end

      def create(project:, text:, idempotency_key:, principal:, scopes:, slug: nil, body: nil,
                 workflow: nil, depends_on: nil, base: nil)
        scope!(scopes, "create")
        if workflow && !workflow.match?(Contract::WORKFLOW_ID)
          raise Hive::UsageError, "workflow must be an installed workflow identifier"
        end
        require_key!(idempotency_key)
        Hive::CommandOperation.verify_receipt_extension!(@store)
        Hive::Commands::New.new(
          project.fetch("name"), text, slug_override: slug, body_override: body,
          workflow: workflow, depends_on: depends_on, base: base,
          idempotency_key: idempotency_key, json: true, structured: true,
          principal: principal, principal_source: "api_token", command_receipt_store: @store
        ).call!
      end

      def answer(project:, task:, binding:, answer:, idempotency_key:, principal:, scopes:, state_reader: nil, remote_handle: nil)
        scope!(scopes, "answer")
        require_key!(idempotency_key)
        Hive::CommandOperation.verify_receipt_extension!(@store)
        verify_target!(project, task)
        Hive::Commands::Answer.write(
          task.slug, project: project.fetch("name"), binding: binding, answer: answer,
          idempotency_key: idempotency_key, principal: principal, principal_source: "api_token",
          command_receipt_store: @store, state_reader: state_reader, remote_handle: remote_handle
        )
      end

      def action(project:, task:, action_id:, observation:, idempotency_key:, principal:, scopes:)
        scope!(scopes, "act")
        unless Hive::OperationalAction::EXECUTABLE_ACTION_IDS.include?(action_id)
          raise Hive::OperationalActionUsageError, "unsupported remote workflow action"
        end
        unless observation.to_s.match?(/\A[0-9a-f]{64}\z/)
          raise Hive::OperationalActionUsageError, "a fresh workflow observation is required"
        end
        verify_target!(project, task)
        operation(project, task, command: "act", key: idempotency_key, principal: principal,
          request: { "action_id" => action_id, "observation" => observation }) do
          with_current_task(project, task) do |current|
            target = "#{project.fetch('name')}:#{current.slug}"
            Hive::OperationalAction.assert_current!(current, project: project.fetch("name"),
              action_id: action_id, target: target, observation_token: observation)
            row = Hive::OperationalAction.observed_row(current, project: project.fetch("name"))
            effect = Hive::WorkflowAdmission.effect_for(task: current, row: row, action_id: action_id, project: project)
            authorize_effect!(effect, scopes: scopes, action: true)
            authority = authority_for(project, current, principal, effect).merge(
              "action_id" => action_id, "observation" => observation,
              "execution_observation" => Hive::WorkflowAdmission.execution_observation(current, row)
            )
            if action_id == Hive::OperationalAction::RETRY_ACTION_ID
              retry_admission(project, current, row, authority)
            else
              argv = [ "hive", "act", action_id, target, "--observation", observation,
                       "--project", project.fetch("name") ]
              queue(project, current, argv, authority)
            end
          end
        end
      end

      def approve(project:, task:, stage:, generation:, idempotency_key:, principal:, scopes:)
        scope!(scopes, "answer")
        verify_target!(project, task)
        operation(project, task, command: "approve", key: idempotency_key, principal: principal,
          request: { "from" => stage, "generation" => generation, "project" => project.fetch("name"), "force" => false }) do
          with_current_task(project, task) do |current|
            authority = authority_for(project, current, principal, { "kind" => "approve", "force" => false }).merge(
              "stage" => stage, "generation" => generation
            )
            Hive::WorkflowAdmission.verify_approval!(task: current, project: project.fetch("name"), authority: authority)
            argv = [ "hive", "approve", current.slug, "--from", stage, "--project", project.fetch("name") ]
            queue(project, current, argv, authority)
          end
        end
      end

      def authorize_effect!(effect, scopes:, action:)
        scope!(scopes, "act") if action
        scope!(scopes, "answer") if effect.fetch("kind") == "approve"
        true
      end

      private

      def scope!(scopes, required)
        return if Array(scopes).include?(required)
        raise Hive::Remote::AdmissionRefused.new(code: "insufficient_scope", message: "insufficient token scope", status: 403)
      end

      def require_key!(key)
        raise Hive::UsageError, "an idempotency key is required" if key.to_s.empty?
      end

      def verify_target!(project, task)
        unless task.is_a?(Hive::Task) && File.realpath(task.project_root) == File.realpath(project.fetch("path"))
          raise Hive::InvalidTaskPath, "task does not belong to the selected project"
        end
      end

      def with_current_task(project, task)
        Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: "remote_admission", create: false) do
          current = Hive::TaskResolver.new(task.slug, project_filter: project.fetch("name")).resolve
          unless current.id == task.id && File.realpath(current.folder) == File.realpath(task.folder)
            raise Hive::StaleOperationalObservation, "task changed before remote admission"
          end
          yield current
        end
      end

      def operation(project, task, command:, key:, principal:, request:, &block)
        require_key!(key)
        Hive::CommandOperation.new(
          key: key, command: command, mode: "remote", target: "#{project.fetch('name')}:#{task.slug}",
          project_root: project.fetch("path"), project_roots: [ project.fetch("path") ], request: request,
          principal: principal, principal_source: "api_token", structured: true, json: true, display_json: false,
          retry_horizon_expires_at: (@clock.call + Hive::CommandReceiptPruner::RETENTION_SECONDS).utc.iso8601(6),
          store: @store
        ).call(&block)
      end

      def authority_for(project, task, principal, effect)
        { "principal" => principal, "project" => project.fetch("name"), "task_id" => task.id,
          "slug" => task.slug, "effect" => effect }
      end

      def queue(project, task, argv, authority)
        intended = if authority.dig("effect", "kind") == "stage_action"
          Hive::Workflows.for_verb(authority.dig("effect", "verb")).fetch(:target)
        else
          Hive::WorkflowAdmission.stage_for(task)
        end
        generation = Hive::Attempts::Generation.resolve(task: task, project: project.fetch("name"), intended_stage: intended)
        request_id = Hive::Bot::DispatchRequestWriter.write!(
          project: project.fetch("name"), slug: task.slug, argv: argv, trigger: "api",
          task_id: task.id, expected_stage: Hive::WorkflowAdmission.stage_for(task), task_generation: generation.task_generation,
          repository: @repository, remote_authority: authority,
          command_lifecycle: Hive::CommandDispatchLifecycle.new(repository: @repository, store: @store)
        )
        admission(task, request_id: request_id)
      end

      def retry_admission(project, task, row, authority)
        unless Hive::Config.load(task.project_root).dig("daemon", "enabled") == true
          command = Shellwords.join([ "hive", "act", "workflow.retry", "#{project.fetch('name')}:#{task.slug}",
            "--observation", authority.fetch("observation"), "--project", project.fetch("name"), "--json" ])
          raise AdmissionRefused.new(code: "dispatcher_unavailable", status: 503,
            message: "daemon dispatch is disabled for #{project.fetch('name')}; no remote dispatcher is available. Run locally: #{command}")
        end
        context = Hive::CommandOperation.current_context
        verb = authority.dig("effect", "verb")
        row = row.merge("suggested_command" => Shellwords.join([
          "hive", verb, task.slug, "--project", project.fetch("name"),
          verb == "run" ? "--stage" : "--from", Hive::WorkflowAdmission.stage_for(task), "--json"
        ]))
        guard = lambda do |locked_task|
          Hive::WorkflowAdmission.verify_action!(task: locked_task, project: project.fetch("name"),
            action_id: authority.fetch("action_id"), observation: authority.fetch("observation"), authority: authority)
        end
        result = Hive::Recovery::API.recover!(row: row, project: project.fetch("name"), requestor: "action",
          observation_token: authority.fetch("observation"), request_id: context.transport_request_id,
          admission_guard: guard, command_context: context, remote_authority: authority,
          coordinator: Hive::Daemon::RecoveryCoordinator.new(dispatch_repository: @repository))
        recovery = result.to_h
        unless recovery["request_id"]
          raise AdmissionRefused.new(code: "unavailable", status: 503, message: "remote recovery admission was refused")
        end
        admission(task, request_id: recovery.fetch("request_id"))
      end

      def admission(task, request_id:, queued: true)
        { "ok" => true, "queued" => queued, "state" => queued ? "queued" : "unavailable",
          "request_id" => request_id, "task_id" => task.id, "slug" => task.slug,
          "stage" => Hive::WorkflowAdmission.stage_for(task) }
      end
    end
  end
end
