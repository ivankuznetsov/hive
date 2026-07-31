require "json"
require "time"
require "hive/errors"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Canonical outcome envelope for one qualification lane attempt.
      # Passed/failed/timeout values may become the immutable completion
      # sentinel; blocked values live only in the append-only diagnostic
      # ledger and never prevent a later authorized attempt. Failure reasons
      # are typed codes, never subprocess/provider prose.
      class QualificationLaneResult
        SCHEMA = "hive-patrol-qualification-lane-result".freeze
        SCHEMA_VERSION = 1
        MAX_BYTES = 16 * 1024
        KEYS = %w[
          ended_at exit_code failure_reason lane run_id schema
          schema_version started_at status target_sha256
        ].freeze
        STATUSES = %w[blocked failed passed timeout].freeze
        BLOCKED_REASONS = %w[
          credentials_unavailable installed_target_unavailable
          live_lane_not_authorized provider_authentication_failed
          provider_credit_exhausted provider_rate_limited provider_timeout
          provider_transport_failed provider_unavailable
          scenario_driver_not_configured
        ].freeze
        FAILED_REASONS = %w[
          candidate_execution_failed evidence_verification_failed
          internal_error provider_failed scenario_failed
        ].freeze
        TIMEOUT_REASONS = %w[lane_timeout].freeze
        FAILURE_REASONS = (
          BLOCKED_REASONS + FAILED_REASONS + TIMEOUT_REASONS
        ).freeze
        DIGEST = /\A[0-9a-f]{64}\z/

        attr_reader :payload

        class << self
          def build(run_id:, lane:, status:, started_at:, ended_at:,
                    target_sha256:, exit_code: nil, failure_reason: nil)
            value = {
              "schema" => SCHEMA,
              "schema_version" => SCHEMA_VERSION,
              "run_id" => run_id.to_s,
              "lane" => lane.to_s,
              "status" => status.to_s,
              "started_at" => timestamp(started_at),
              "ended_at" => timestamp(ended_at),
              "target_sha256" => target_sha256.to_s,
              "exit_code" => exit_code,
              "failure_reason" => failure_reason
            }
            new(validate(value))
          end

          def load(bytes)
            malformed! unless bytes.is_a?(String) &&
                              bytes.bytesize <= MAX_BYTES
            value = JSON.parse(bytes)
            malformed! unless bytes == canonical(value)
            new(validate(value))
          rescue JSON::ParserError, EncodingError
            malformed!
          end

          def canonical(value)
            Hive::WorkflowPackage::CanonicalJSON.generate(value)
          end

          private

          def validate(value)
            malformed! unless value.is_a?(Hash) &&
                              value.keys.sort == KEYS.sort &&
                              value["schema"] == SCHEMA &&
                              value["schema_version"] == SCHEMA_VERSION &&
                              QualificationRunDescriptor::RUN_ID.match?(
                                value["run_id"].to_s
                              ) &&
                              QualificationRunDescriptor::LANES.include?(
                                value["lane"].to_s
                              ) &&
                              STATUSES.include?(value["status"].to_s) &&
                              DIGEST.match?(value["target_sha256"].to_s)
            started_at = exact_timestamp(value["started_at"])
            ended_at = exact_timestamp(value["ended_at"])
            malformed! if ended_at < started_at
            validate_outcome!(value)
            immutable(value)
          rescue ArgumentError, KeyError, NoMethodError, TypeError
            malformed!
          end

          def validate_outcome!(value)
            status = value.fetch("status")
            reason = value["failure_reason"]
            exit_code = value["exit_code"]
            case status
            when "passed"
              malformed! unless exit_code == 0 && reason.nil?
            when "blocked"
              malformed! unless exit_code.nil? &&
                                BLOCKED_REASONS.include?(reason)
            when "failed"
              malformed! unless exit_code.is_a?(Integer) &&
                                exit_code.between?(1, 255) &&
                                FAILED_REASONS.include?(reason)
            when "timeout"
              malformed! unless exit_code.nil? &&
                                TIMEOUT_REASONS.include?(reason)
            else
              malformed!
            end
          end

          def timestamp(value)
            time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
            time.utc.iso8601(6)
          rescue ArgumentError, TypeError
            malformed!
          end

          def exact_timestamp(value)
            malformed! unless value.is_a?(String)
            time = Time.iso8601(value)
            malformed! unless value == time.utc.iso8601(6)
            time.utc
          end

          def immutable(value)
            case value
            when Hash
              value.to_h do |key, child|
                [ key.dup.freeze, immutable(child) ]
              end.freeze
            when Array
              value.map { |child| immutable(child) }.freeze
            when String
              value.dup.freeze
            when Integer, TrueClass, FalseClass, NilClass
              value
            else
              malformed!
            end
          end

          def malformed!
            raise Hive::ConfigError,
                  "patrol qualification lane result is malformed"
          end
        end

        def initialize(payload)
          @payload = payload
          freeze
        end

        def to_h = payload
        def run_id = payload.fetch("run_id")
        def lane = payload.fetch("lane")
        def status = payload.fetch("status")
        def target_sha256 = payload.fetch("target_sha256")
        def exit_code = payload["exit_code"]
        def failure_reason = payload["failure_reason"]
        def started_at = Time.iso8601(payload.fetch("started_at"))
        def ended_at = Time.iso8601(payload.fetch("ended_at"))
        def duration_seconds = ended_at - started_at
        def passed? = status == "passed"
        def blocked? = status == "blocked"
        def failed? = %w[failed timeout].include?(status)
      end
    end
  end
end
