require "psych"
require "time"
require "hive/errors"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Strict stimulus-only input for one candidate-side qualification case.
      # Expected decisions, controls, effects, and repository identities remain
      # exclusively in QualificationRunDescriptor and are checked by the host
      # after candidate execution.
      class QualificationScenarioInput
        SCHEMA = "hive-patrol-qualification-scenario".freeze
        SCHEMA_VERSION = 1
        MAX_BYTES = 1024 * 1024
        MAX_FINDINGS = 32
        MAX_FINDINGS_BYTES = 256 * 1024
        TOP_LEVEL_KEYS = %w[
          case_id clock faults module operation reviewer schema schema_version
        ].freeze
        REVIEWER_KEYS = %w[findings].freeze
        OPERATIONS = %w[
          architecture_positive_fixture capacity_deferral
          concurrent_duplicate_delivery cooldown_retry launch_failure
          new_commit ordinary_clean_fixture ordinary_positive_fixture
          partial_failure
          quota_deferral reconciliation_failure restart same_commit
          timer_due timer_not_due timer_reset_reload
        ].freeze

        attr_reader :payload

        class << self
          def load(bytes, expected_case_id:)
            malformed! unless
              bytes.is_a?(String) &&
                bytes.bytesize <= MAX_BYTES &&
                bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
            value = Psych.safe_load(
              bytes,
              permitted_classes: [],
              permitted_symbols: [],
              aliases: false
            )
            new(
              validate(
                value,
                expected_case_id: expected_case_id.to_s
              )
            )
          rescue Psych::Exception, EncodingError
            malformed!
          end

          private

          def validate(value, expected_case_id:)
            exact!(value, TOP_LEVEL_KEYS)
            malformed! unless
              value["schema"] == SCHEMA &&
                value["schema_version"] == SCHEMA_VERSION
            case_id = value["case_id"].to_s
            malformed! unless
              QualificationRunDescriptor::SAFE_ID.match?(case_id) &&
                case_id == expected_case_id
            malformed! unless
              QualificationRunDescriptor::MODULES.include?(
                value["module"].to_s
              )
            malformed! unless
              OPERATIONS.include?(value["operation"].to_s)
            exact_timestamp!(value["clock"])
            faults = value["faults"]
            malformed! unless
              faults.is_a?(Array) &&
                faults.all? { |fault| fault.is_a?(String) } &&
                faults.uniq.length == faults.length &&
                faults == faults.sort &&
                (
                  faults -
                    QualificationRunDescriptor::REQUIRED_FAULTS
                ).empty?
            reviewer = value["reviewer"]
            exact!(reviewer, REVIEWER_KEYS)
            findings = reviewer["findings"]
            malformed! unless
              findings.is_a?(Array) &&
                findings.length <= MAX_FINDINGS
            immutable_findings = immutable(findings)
            malformed! if
              Hive::WorkflowPackage::CanonicalJSON
                .generate(immutable_findings)
                .bytesize > MAX_FINDINGS_BYTES
            immutable(
              value.merge(
                "reviewer" =>
                  reviewer.merge(
                    "findings" => immutable_findings
                  )
              )
            )
          rescue ArgumentError, KeyError, NoMethodError, TypeError
            malformed!
          end

          def exact_timestamp!(value)
            malformed! unless value.is_a?(String)

            parsed = Time.iso8601(value)
            malformed! unless value == parsed.utc.iso8601(6)
          rescue ArgumentError
            malformed!
          end

          def exact!(value, keys)
            malformed! unless
              value.is_a?(Hash) &&
                value.keys.all? { |key| key.is_a?(String) } &&
                value.keys.sort == keys.sort
          end

          def immutable(value)
            case value
            when Hash
              value.to_h do |key, child|
                malformed! unless key.is_a?(String)

                [ key.dup.freeze, immutable(child) ]
              end.freeze
            when Array
              value.map { |child| immutable(child) }.freeze
            when String
              value.dup.freeze
            when Integer, Float, TrueClass, FalseClass, NilClass
              malformed! unless
                value.is_a?(Integer) ||
                  value == true ||
                  value == false ||
                  value.nil?
              value
            else
              malformed!
            end
          end

          def malformed!
            raise Hive::ConfigError,
                  "patrol qualification scenario input is malformed"
          end
        end

        def initialize(payload)
          @payload = payload
          freeze
        end

        def to_h = payload
        def case_id = payload.fetch("case_id")
        def module_name = payload.fetch("module")
        def operation = payload.fetch("operation")
        def clock = Time.iso8601(payload.fetch("clock"))
        def faults = payload.fetch("faults")
        def reviewer_findings =
          payload.dig("reviewer", "findings")
      end
    end
  end
end
