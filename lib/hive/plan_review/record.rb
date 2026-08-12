require "json"
require "time"
require "hive/plan_review"
require "hive/plan_review/finding"
require "hive/plan_review/identity"

module Hive
  module PlanReview
    class Record
      COMMON_KEYS = %w[
        schema schema_version kind review_id prior_review_id task_id task_generation plan_digest
        policy_fingerprint computed_level effective_level created_at
      ].freeze
      MANIFEST_KEYS = COMMON_KEYS.freeze
      PROJECTION_KEYS = (COMMON_KEYS + %w[
        version candidate_plan_digest state outcome attempt_ids current_attempt_id coverage findings
        decisions routes artifacts blockers required_action degradation_reason execution_allowed updated_at
      ]).freeze
      KINDS = %w[manifest projection].freeze
      STATES = %w[
        uninitialized skipped reviewing retry_scheduled awaiting_decision revising verifying cleared
        degraded_cleared blocked
      ].freeze
      OUTCOMES = %w[skipped cleared degraded_cleared blocked].freeze
      EXECUTABLE_STATES = %w[skipped cleared degraded_cleared].freeze
      COVERAGE_STATUSES = %w[requested completed failed unsupported waived].freeze
      DIGEST = /\A[0-9a-f]{64}\z/
      IDENTIFIER = /\A(?:pr|pra|prd|prf)-[0-9a-f]{64}\z/

      attr_reader :data

      def initialize(attributes)
        @data = Identity.normalize(attributes)
        validate!
        @data = JSON.parse(JSON.generate(@data)).freeze
        freeze
      rescue JSON::GeneratorError, TypeError => e
        raise InvalidRecord, "plan review record is not JSON-safe: #{e.message}"
      end

      def [](key) = data[key.to_s]
      def to_h = JSON.parse(JSON.generate(data))
      def kind = self["kind"]
      def review_id = self["review_id"]
      def prior_review_id = self["prior_review_id"]
      def version = self["version"]
      def task_generation = self["task_generation"]
      def plan_digest = self["plan_digest"]
      def policy_fingerprint = self["policy_fingerprint"]
      def computed_level = self["computed_level"]
      def effective_level = self["effective_level"]
      def state = self["state"]
      def outcome = self["outcome"]
      def required_action = self["required_action"]
      def execution_allowed? = self["execution_allowed"] == true

      private

      def validate!
        unless data["schema"] == SCHEMA && data["schema_version"] == SCHEMA_VERSION
          raise InvalidRecord, "invalid plan review schema envelope"
        end
        unless KINDS.include?(kind)
          raise InvalidRecord, "plan review kind must be one of #{KINDS.inspect}"
        end
        allowed = kind == "manifest" ? MANIFEST_KEYS : PROJECTION_KEYS
        missing = allowed - data.keys
        unknown = data.keys - allowed
        raise InvalidRecord, "plan review record missing fields: #{missing.join(', ')}" unless missing.empty?
        raise InvalidRecord, "plan review record has unknown fields: #{unknown.join(', ')}" unless unknown.empty?

        validate_identity!
        validate_projection! if kind == "projection"
      end

      def validate_identity!
        raise InvalidRecord, "invalid plan review id" unless review_id.to_s.match?(IDENTIFIER)
        if prior_review_id && !prior_review_id.to_s.match?(IDENTIFIER)
          raise InvalidRecord, "invalid prior plan review id"
        end
        unless self["task_id"].is_a?(String) && !self["task_id"].empty?
          raise InvalidRecord, "plan review task_id must be non-empty"
        end
        unless (task_generation.is_a?(String) && !task_generation.empty?) || task_generation.is_a?(Integer)
          raise InvalidRecord, "plan review task_generation must be non-empty"
        end
        %w[plan_digest policy_fingerprint].each do |key|
          raise InvalidRecord, "plan review #{key} must be a SHA-256 digest" unless self[key].to_s.match?(DIGEST)
        end
        %w[computed_level effective_level].each do |key|
          Hive::PlanReview.level!(self[key], label: "plan review #{key}")
        rescue Hive::ConfigError => e
          raise InvalidRecord, e.message
        end
        parse_time!(self["created_at"], "created_at")
      end

      def validate_projection!
        unless version.is_a?(Integer) && version.positive?
          raise InvalidRecord, "plan review projection version must be positive"
        end
        if self["candidate_plan_digest"] && !self["candidate_plan_digest"].to_s.match?(DIGEST)
          raise InvalidRecord, "candidate plan digest must be SHA-256"
        end
        raise InvalidRecord, "unknown plan review state #{state.inspect}" unless STATES.include?(state)
        if outcome && !OUTCOMES.include?(outcome)
          raise InvalidRecord, "unknown plan review outcome #{outcome.inspect}"
        end
        validate_arrays!
        validate_artifacts!
        parse_time!(self["updated_at"], "updated_at")

        executable = EXECUTABLE_STATES.include?(state) && outcome == state && self["blockers"].empty?
        unless execution_allowed? == executable
          raise InvalidRecord, "execution_allowed conflicts with review state, outcome, or blockers"
        end
      end

      def validate_arrays!
        %w[attempt_ids coverage findings decisions routes blockers].each do |key|
          raise InvalidRecord, "plan review #{key} must be an Array" unless self[key].is_a?(Array)
        end
        unless self["attempt_ids"].all? { |id| id.to_s.match?(IDENTIFIER) }
          raise InvalidRecord, "plan review attempt_ids contains an invalid id"
        end
        current = self["current_attempt_id"]
        if current && (!current.to_s.match?(IDENTIFIER) || !self["attempt_ids"].include?(current))
          raise InvalidRecord, "current attempt must belong to attempt_ids"
        end
        self["coverage"].each { |entry| validate_coverage!(entry) }
        self["findings"].each { |entry| Finding.new(entry) }
      end

      def validate_coverage!(entry)
        unless entry.is_a?(Hash) && entry["name"].is_a?(String) &&
               (entry["required"] == true || entry["required"] == false) &&
               COVERAGE_STATUSES.include?(entry["status"])
          raise InvalidRecord, "invalid plan review coverage entry"
        end
      end

      def validate_artifacts!
        artifacts = self["artifacts"]
        raise InvalidRecord, "plan review artifacts must be a mapping" unless artifacts.is_a?(Hash)
        artifacts.each_value do |reference|
          unless reference.is_a?(Hash) && reference.keys.sort == %w[bytes path sha256] &&
                 reference["path"].is_a?(String) && reference["sha256"].to_s.match?(DIGEST) &&
                 reference["bytes"].is_a?(Integer) && reference["bytes"] >= 0
            raise InvalidRecord, "invalid plan review artifact reference"
          end
        end
      end

      def parse_time!(value, label)
        Time.iso8601(value)
      rescue ArgumentError, TypeError
        raise InvalidRecord, "plan review #{label} must be ISO-8601"
      end
    end
  end
end
