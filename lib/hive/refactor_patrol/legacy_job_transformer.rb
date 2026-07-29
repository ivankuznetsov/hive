require "json"

module Hive
  module RefactorPatrol
    # Pure, one-way conversion of the released JobStore v2 aggregate into the
    # v3 authority shape. It deliberately knows only the released aggregate;
    # the unreleased occurrence-binding draft is not a supported input.
    class LegacyJobTransformer
      SOURCE_VERSION = 2
      SOURCE_KEYS = %w[
        schema schema_version job_id source analysis_sha policy state complete
        dispositions feature_results review_errors zero_reason attempts actions
        created_at updated_at
      ].freeze
      ATTEMPT_KINDS = %w[
        discovery_claim discovery_block action_block
      ].freeze
      DIAGNOSTIC_KINDS = %w[discovery_block action_block].freeze

      def initialize(target_version:, validator:, corrupt_record:,
                     inconsistent_record:)
        @target_version = Integer(target_version)
        @validator = validator
        @corrupt_record = corrupt_record
        @inconsistent_record = inconsistent_record
      end

      def transform(data, occurrence_id:, intake_transition_id:, path:)
        source = source_record!(data, path)
        replacement = json_copy(source)
        replacement["schema_version"] = @target_version
        replacement["occurrence_id"] = occurrence_id
        replacement["intake_transition_id"] = intake_transition_id
        replacement["attempts"] = migrate_attempts(
          replacement.fetch("attempts"), occurrence_id, path
        )
        replacement["actions"] = migrate_actions(
          replacement.fetch("actions"), occurrence_id, path
        )
        @validator.validate_job!(replacement, path: path)
      rescue @corrupt_record, @inconsistent_record
        raise
      rescue KeyError, TypeError, NoMethodError, JSON::GeneratorError,
             JSON::ParserError, ArgumentError => error
        corrupt!(
          "released refactor patrol v2 job is malformed " \
          "(#{error.class}: #{error.message})",
          path
        )
      end

      private

      def source_record!(data, path)
        corrupt!("released refactor patrol v2 job must be an object", path) unless
          data.is_a?(Hash)
        missing = SOURCE_KEYS - data.keys
        unknown = data.keys - SOURCE_KEYS
        corrupt!(
          "released refactor patrol v2 job is missing keys #{missing.inspect}",
          path
        ) unless missing.empty?
        inconsistent!(
          "released refactor patrol v2 job has unknown keys #{unknown.inspect}",
          path
        ) unless unknown.empty?
        inconsistent!("unexpected refactor patrol job schema", path) unless
          data.fetch("schema") == "hive-refactor-patrol-job"
        inconsistent!(
          "unsupported refactor patrol source schema_version " \
          "#{data.fetch('schema_version').inspect}",
          path
        ) unless data.fetch("schema_version") == SOURCE_VERSION
        corrupt!("released refactor patrol v2 attempts must be an array", path) unless
          data.fetch("attempts").is_a?(Array)
        corrupt!("released refactor patrol v2 actions must be an array", path) unless
          data.fetch("actions").is_a?(Array)
        data
      end

      def migrate_attempts(attempts, occurrence_id, path)
        generations = Hash.new(0)
        attempts.map do |attempt|
          corrupt!("released refactor patrol v2 attempt must be an object", path) unless
            attempt.is_a?(Hash)
          kind = attempt["kind"].to_s
          inconsistent!(
            "unsupported released refactor patrol v2 attempt kind " \
            "#{kind.inspect}",
            path
          ) unless ATTEMPT_KINDS.include?(kind)
          if attempt.key?("occurrence_id") ||
             attempt.key?("generation") && DIAGNOSTIC_KINDS.include?(kind) ||
             attempt.key?("transitions")
            inconsistent!(
              "released refactor patrol v2 attempt mixes v3 authority fields",
              path
            )
          end

          migrated = attempt.merge(
            "occurrence_id" => occurrence_id,
            "transitions" => []
          )
          if DIAGNOSTIC_KINDS.include?(kind)
            generations[kind] += 1
            migrated["generation"] = generations.fetch(kind)
          end
          migrated
        end
      end

      def migrate_actions(actions, occurrence_id, path)
        actions.map do |action|
          corrupt!("released refactor patrol v2 action must be an object", path) unless
            action.is_a?(Hash)
          inconsistent!(
            "released refactor patrol v2 action mixes v3 transition history",
            path
          ) if action.key?("transitions")
          migrated = action.merge("transitions" => [])
          next migrated unless migrated.key?("claims")

          claims = migrated.fetch("claims")
          corrupt!("released refactor patrol v2 action claims must be an array", path) unless
            claims.is_a?(Array)
          migrated["claims"] = claims.map do |claim|
            corrupt!("released refactor patrol v2 action claim must be an object", path) unless
              claim.is_a?(Hash)
            inconsistent!(
              "released refactor patrol v2 action claim mixes v3 authority",
              path
            ) if claim.key?("occurrence_id")
            claim.merge("occurrence_id" => occurrence_id)
          end
          migrated
        end
      end

      def json_copy(value)
        JSON.parse(JSON.generate(value))
      end

      def corrupt!(message, path)
        raise @corrupt_record.new(message, path: path)
      end

      def inconsistent!(message, path)
        raise @inconsistent_record.new(message, path: path)
      end
    end
  end
end
