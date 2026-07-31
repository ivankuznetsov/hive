require "digest"
require "hive/errors"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Closed, bounded diagnostic contract for a candidate process that
      # failed after the trusted host had spawned it. It deliberately omits
      # exception prose, process ids, paths, environment, and output content.
      class QualificationScenarioProcess
        FAILURE_SCHEMA =
          "hive-patrol-qualification-process-failure".freeze
        FAILURE_SCHEMA_VERSION = 1
        FAILURE_MAX_BYTES = 8 * 1024
        FAILURE_PHASES = %w[
          identity wait terminate capture sandbox_finalize
          target_verify custody_verify result_finalize
        ].freeze
        FAILURE_REASONS = %w[
          identity_unavailable identity_changed
          termination_unconfirmed capture_unconfirmed target_changed
          custody_unverified io_failure controller_failure
        ].freeze
        FAILURE_KEYS = %w[
          cleanup duration_seconds executable_sha256 exit_status
          failure_sha256 installed_inventory_sha256 kind network_isolated
          phase process_state reason ruby_sha256 sandbox_profile_sha256
          schema schema_version signal source_inventory_sha256 stderr
          stdout timed_out
        ].freeze
        FAILURE_STREAM_KEYS = %w[bytes sha256 truncated].freeze
        FAILURE_CLEANUP_KEYS = %w[
          kill_authority live_processes status
        ].freeze
        FAILURE_DIGEST = /\A[0-9a-f]{64}\z/

        class FailureEvidence
          attr_reader :payload

          def self.build(**values)
            body = {
              "schema" => FAILURE_SCHEMA,
              "schema_version" => FAILURE_SCHEMA_VERSION,
              "kind" => "post_spawn_failure"
            }.merge(values.transform_keys(&:to_s))
            from_h(
              body.merge(
                "failure_sha256" =>
                  Digest::SHA256.hexdigest(
                    "qualification-process-failure\0" \
                    "#{canonical(body)}"
                  )
              )
            )
          end

          def self.from_h(value)
            payload = immutable(value)
            malformed! unless
              payload.is_a?(Hash) &&
                payload.keys.sort == FAILURE_KEYS &&
                payload.fetch("schema") == FAILURE_SCHEMA &&
                payload.fetch("schema_version") ==
                  FAILURE_SCHEMA_VERSION &&
                payload.fetch("kind") == "post_spawn_failure" &&
                FAILURE_PHASES.include?(payload.fetch("phase")) &&
                FAILURE_REASONS.include?(payload.fetch("reason")) &&
                %w[exited signaled unverified].include?(
                  payload.fetch("process_state")
                ) &&
                [ true, false ].include?(
                  payload.fetch("timed_out")
                ) &&
                [ true, false ].include?(
                  payload.fetch("network_isolated")
                )
            validate_process_state!(payload)
            validate_stream!(payload.fetch("stdout"))
            validate_stream!(payload.fetch("stderr"))
            validate_cleanup!(payload.fetch("cleanup"))
            %w[
              executable_sha256 installed_inventory_sha256 ruby_sha256
              sandbox_profile_sha256 source_inventory_sha256
              failure_sha256
            ].each do |key|
              malformed! unless
                FAILURE_DIGEST.match?(payload.fetch(key).to_s)
            end
            duration = payload.fetch("duration_seconds")
            malformed! unless
              duration.is_a?(Numeric) &&
                duration.finite? &&
                duration.between?(0, 3_600)
            body =
              payload.reject do |key, _|
                key == "failure_sha256"
              end
            malformed! unless
              payload.fetch("failure_sha256") ==
                Digest::SHA256.hexdigest(
                  "qualification-process-failure\0" \
                  "#{canonical(body)}"
                )
            malformed! if canonical(payload).bytesize >
                          FAILURE_MAX_BYTES

            new(payload: payload).freeze
          rescue ArgumentError, EncodingError, KeyError, NoMethodError,
                 TypeError
            malformed!
          end

          def initialize(payload:)
            @payload = payload
            freeze
          end

          def to_h = payload
          def sha256 = payload.fetch("failure_sha256")

          class << self
            private

            def validate_process_state!(payload)
              state = payload.fetch("process_state")
              exit_status = payload.fetch("exit_status")
              signal = payload.fetch("signal")
              valid =
                case state
                when "exited"
                  exit_status.is_a?(Integer) &&
                    exit_status.between?(0, 255) &&
                    signal.nil?
                when "signaled"
                  exit_status.nil? &&
                    signal.is_a?(Integer) &&
                    signal.between?(1, 255)
                else
                  exit_status.nil? && signal.nil?
                end
              malformed! unless valid
            end

            def validate_stream!(value)
              return if value.nil?

              malformed! unless
                value.is_a?(Hash) &&
                  value.keys.sort == FAILURE_STREAM_KEYS &&
                  value.fetch("bytes").is_a?(Integer) &&
                  value.fetch("bytes").between?(
                    0, (2**63) - 1
                  ) &&
                  FAILURE_DIGEST.match?(
                    value.fetch("sha256").to_s
                  ) &&
                  [ true, false ].include?(
                    value.fetch("truncated")
                  )
            end

            def validate_cleanup!(value)
              malformed! unless
                value.is_a?(Hash) &&
                  value.keys.sort == FAILURE_CLEANUP_KEYS &&
                  %w[passed failed unverified].include?(
                    value.fetch("status")
                  ) &&
                  value.fetch("kill_authority") ==
                    "host_pid_namespace"
              live = value.fetch("live_processes")
              malformed! unless [ 0, nil ].include?(live)
              if value.fetch("status") == "passed"
                malformed! unless live == 0
              else
                malformed! unless live.nil?
              end
            end

            def immutable(value)
              case value
              when Hash
                value.keys.sort.to_h do |key|
                  malformed! unless key.is_a?(String)
                  [
                    key.dup.freeze,
                    immutable(value.fetch(key))
                  ]
                end.freeze
              when Array
                value.map { |child| immutable(child) }.freeze
              when String
                malformed! unless value.valid_encoding?
                value.dup.freeze
              when Integer, TrueClass, FalseClass, NilClass
                value
              when Float
                malformed! unless value.finite?
                value
              else
                malformed!
              end
            end

            def canonical(value)
              Hive::WorkflowPackage::CanonicalJSON.generate(value)
            end

            def malformed!
              raise Hive::ConfigError,
                    "patrol qualification process failure evidence " \
                    "is malformed"
            end
          end
        end

        class PostSpawnFailure < Hive::ConfigError
          attr_reader :evidence

          def initialize(evidence:)
            @evidence = FailureEvidence.from_h(evidence.to_h)
            super(
              "patrol qualification candidate process failed after spawn"
            )
          end
        end
      end
    end
  end
end
