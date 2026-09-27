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
                     executor: Hive::OperationalAction::Executor.new,
                     project: nil, idempotency_key: nil, command_receipt_store: nil)
        @action_id = action_id
        @target = target
        @observation = observation
        @json = json
        @executor = executor
        @project_filter = project
        @idempotency_key = idempotency_key
        @command_receipt_store = command_receipt_store
      end

      def call
        call_with_envelope do
          invoke = lambda do
            validate!
            result = @executor.execute(
              action_id: @action_id,
              target: @target,
              observation_token: @observation
            )
            emit_success(result)
          end
          @idempotency_key ? command_operation.call(&invoke) : invoke.call
        end
      end

      def envelope_schema = "hive-act"

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
          project_root: lambda {
            Hive::TaskResolver.new(@target, project_filter: @project_filter).resolve.project_root
          },
          json: @json,
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
        if @json
          puts JSON.generate(
            "schema" => "hive-act",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-act"),
            "ok" => true,
            "action_id" => @action_id,
            "target" => @target,
            "observation_token" => @observation,
            "result" => result
          )
          @stdout_written = true
        else
          if (recovery = result["recovery"])
            puts recovery_summary(recovery)
          else
            puts "advanced #{@target} — #{result.fetch('task_state')} at " \
                 "#{result.fetch('stage')} (#{result.fetch('marker')})"
          end
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
    argv, command_index, value_options: %w[--observation]
  ).first(2)
  {
    schema: "hive-act",
    error_kind: "usage",
    extras: { "action_id" => action_id.to_s, "target" => target.to_s }
  }
end
