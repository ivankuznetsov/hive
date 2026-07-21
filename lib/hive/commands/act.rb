require "json"
require "hive/operational_action"

module Hive
  module Commands
    class Act
      include Hive::Schemas::EnvelopeEmitter

      def initialize(action_id, target, observation:, json: false,
                     executor: Hive::OperationalAction::Executor.new)
        @action_id = action_id
        @target = target
        @observation = observation
        @json = json
        @executor = executor
      end

      def call
        call_with_envelope do
          validate!
          result = @executor.execute(
            action_id: @action_id,
            target: @target,
            observation_token: @observation
          )
          emit_success(result)
        end
      end

      def envelope_schema = "hive-act"

      def envelope_extras
        { "action_id" => @action_id.to_s, "target" => @target.to_s }
      end

      def envelope_error_kind(error)
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
          puts "advanced #{@target} — #{result.fetch('task_state')} at " \
               "#{result.fetch('stage')} (#{result.fetch('marker')})"
        end
      end
    end
  end
end
