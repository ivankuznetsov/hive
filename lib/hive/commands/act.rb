require "json"
require "hive/operational_action"
require "hive/command_operation"
require "hive/command_error_kind"
require "hive/task_resolver"

module Hive
  module Commands
    class Act
      include Hive::Schemas::EnvelopeEmitter

      def initialize(action_id, target, observation:, json: false,
                     executor: nil,
                     project: nil, idempotency_key: nil, command_receipt_store: nil,
                     structured: false, principal: nil, principal_source: "local_cli")
        @action_id = action_id
        @target = target
        @observation = observation
        @json = json
        authority = if defined?(Hive::Attempts::Context)
          Hive::Attempts::Context.current&.remote_authority
        end
        @executor = executor || Hive::OperationalAction::Executor.new(remote_authority: authority)
        @project_filter = project
        @idempotency_key = idempotency_key
        @command_receipt_store = command_receipt_store
        @structured = structured
        @principal = principal
        @principal_source = principal_source
      end

      def call
        call_with_envelope do
          invoke = lambda do
            validate!
            result = with_stage_stdout do
              @executor.execute(
                action_id: @action_id,
                target: @target,
                observation_token: @observation
              )
            end
            emit_success(result)
          end
          payload = @idempotency_key ? command_operation.call(&invoke) : invoke.call
          if @idempotency_key
            render_success(payload)
          end
          recovery = payload.dig("result", "recovery")
          if recovery && recovery["status"] == "terminal" &&
              !%w[succeeded success completed terminal_replay].include?(recovery["terminal_outcome"])
            raise Hive::TaskInErrorState, "retry attempt #{recovery['attempt_id']} ended #{recovery['terminal_outcome']}"
          end
          payload
        end
      end

      def envelope_schema = "hive-act"
      def envelope_enabled? = @json && !@structured

      def envelope_extras
        { "action_id" => @action_id.to_s, "target" => @target.to_s }
      end

      def envelope_error_kind(error)
        typed = Hive::CommandErrorKind.typed(error)
        return typed if typed
        case error
        when Hive::AmbiguousSlug then "ambiguous_target"
        when Hive::OperationalActionUsageError, Hive::InvalidTaskPath then "usage"
        when Hive::StaleOperationalObservation, Hive::WrongStage then "stale_observation"
        when Hive::ConcurrentRunError then "concurrent_run"
        when Hive::DependencyWaitError then "dependency_wait"
        when Hive::DependencyAdmissionError then "admission_error"
        when Hive::ConfigError then "config"
        when Hive::InternalError then "internal"
        else "error"
        end
      end

      def envelope_serialization_failure_policy = :raise

      private

      def with_stage_stdout
        return yield unless @json

        Hive::CommandOperation::CAPTURE_MUTEX.synchronize do
          previous = $stdout
          File.open(File::NULL, "w") do |sink|
            begin
              $stdout = Hive::CommandOperation::ThreadRoutedOutput.new(
                capture_thread: Thread.current, captured: sink, passthrough: previous
              )
              yield
            ensure
              $stdout = previous
            end
          end
        end
      end

      def command_operation
        Hive::CommandOperation.new(
          key: @idempotency_key,
          command: "act",
          target: @target,
          request: {
            "action_id" => @action_id,
            "observation" => @observation,
            "project" => @project_filter
          },
          project_roots: lambda {
            project_name, = qualified_target
            Hive::CommandOperation.registered_project_roots(
              target: @target, project: project_name
            )
          },
          project_root: lambda {
            project_name, slug = qualified_target
            Hive::TaskResolver.new(slug, project_filter: project_name).resolve.project_root
          },
          json: true,
          structured: true,
          display_json: false,
          principal: @principal,
          principal_source: @principal_source,
          failure_payload: ->(error) { envelope_payload_for(error) },
          text_renderer: ->(payload) { text_success(payload.fetch("result")) },
          store: @command_receipt_store || Hive::CommandReceiptStore.new
        )
      end

      def validate!
        if @action_id.to_s.empty? || @target.to_s.empty?
          raise Hive::OperationalActionUsageError, "ACTION_ID and TARGET are required"
        end
        unless @observation.to_s.match?(/\A[0-9a-f]{64}\z/)
          raise Hive::OperationalActionUsageError,
                "--observation must be the 64-character token from a fresh operational snapshot"
        end
      end

      def emit_success(result)
        payload = {
          "schema" => "hive-act",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-act"),
          "ok" => true,
          "action_id" => @action_id,
          "target" => @target,
          "observation_token" => @observation,
          "result" => result
        }
        render_success(payload) unless @idempotency_key
        payload
      end

      def render_success(payload)
        return payload if @structured
        if @json
          puts JSON.generate(payload)
          @stdout_written = true
        else
          print text_success(payload.fetch("result"))
        end
        payload
      end

      def qualified_target
        project, slug = @target.to_s.split(":", 2)
        if project.to_s.empty? || slug.to_s.empty? || slug.include?(File::SEPARATOR)
          raise Hive::OperationalActionUsageError,
                "TARGET must be the exact project:slug emitted by operational status"
        end
        if @project_filter && @project_filter.to_s != project
          raise Hive::OperationalActionUsageError,
                "--project must match the project in TARGET"
        end
        [ project, slug ]
      end

      def text_success(result)
        if (recovery = result["recovery"])
          recovery_summary(recovery)
        else
          "advanced #{@target} — #{result.fetch('task_state')} at " \
            "#{result.fetch('stage')} (#{result.fetch('marker')})\n"
        end
      end

      def recovery_summary(recovery)
        "#{Hive::Daemon::RecoveryCoordinator::Receipt.from_h(recovery).human_summary}\n"
      end
    end
  end
end

# The pre-dispatch JSON usage contract for this command boundary preserves the
# action identity argv named, so Thor rejections that never reach the handler
# still carry the attempted action/target (see Hive::CliUsageContracts).
require "hive/cli_usage_contracts"

Hive::CliUsageContracts.declare("act") do |argv, command_index:, option_argv:|
  action_id, target = Hive::CliUsageContracts.positionals(
    argv, command_index, value_options: %w[--observation --idempotency-key]
  ).first(2)
  {
    schema: "hive-act",
    error_kind: "usage",
    extras: { "action_id" => action_id.to_s, "target" => target.to_s }
  }
end
