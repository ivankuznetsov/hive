require "json"
require "hive/errors"
require "hive/modules/migration/qualification_scenario_observations"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Canonical candidate-process output for qualification scenarios.
      #
      # Actuals intentionally exclude descriptor identity and decision labels.
      # The trusted host binds them to a run/lane/manifest and classifies each
      # decision only after candidate execution.
      class QualificationScenarioActuals
        SCHEMA =
          "hive-patrol-qualification-scenario-actuals".freeze
        SCHEMA_VERSION = 1
        MAX_BYTES =
          QualificationScenarioObservations::MAX_BYTES
        MAX_ACTUALS =
          QualificationScenarioObservations::MAX_OBSERVATIONS
        TOP_LEVEL_KEYS = %w[actuals schema schema_version].freeze
        ACTUAL_KEYS =
          (
            QualificationScenarioObservations::OBSERVATION_KEYS -
            [ "decision_class" ]
          ).freeze
        VALIDATION_RUN_ID = "patrol-#{"0" * 64}".freeze
        VALIDATION_LANE = "deterministic".freeze
        VALIDATION_MANIFEST_SHA256 = ("0" * 64).freeze

        attr_reader :payload

        class << self
          def load(bytes)
            malformed! unless
              bytes.is_a?(String) &&
                bytes.bytesize <= MAX_BYTES
            value = JSON.parse(bytes)
            malformed! unless bytes == canonical(value)
            new(validate(value))
          rescue JSON::ParserError, EncodingError
            malformed!
          end

          def from_h(value)
            new(validate(immutable(value)))
          end

          def canonical(value)
            Hive::WorkflowPackage::CanonicalJSON.generate(value)
          end

          private

          def validate(value)
            exact!(value, TOP_LEVEL_KEYS)
            malformed! unless
              value["schema"] == SCHEMA &&
                value["schema_version"] == SCHEMA_VERSION
            rows = value["actuals"]
            malformed! unless
              rows.is_a?(Array) &&
                !rows.empty? &&
                rows.length <= MAX_ACTUALS
            rows.each { |row| exact!(row, ACTUAL_KEYS) }
            validated =
              QualificationScenarioObservations.from_h(
                "schema" =>
                  QualificationScenarioObservations::SCHEMA,
                "schema_version" =>
                  QualificationScenarioObservations::SCHEMA_VERSION,
                "run_id" => VALIDATION_RUN_ID,
                "lane" => VALIDATION_LANE,
                "scenario_manifest_sha256" =>
                  VALIDATION_MANIFEST_SHA256,
                "observations" =>
                  rows.map do |row|
                    row.merge(
                      "decision_class" =>
                        "candidate-actual-unclassified"
                    )
                  end
              ).observations.map do |row|
                row.reject do |key, _child|
                  key == "decision_class"
                end.freeze
              end.freeze
            immutable(value.merge("actuals" => validated))
          rescue Hive::ConfigError, ArgumentError, KeyError,
                 NoMethodError, TypeError
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
            when Integer, TrueClass, FalseClass, NilClass
              value
            else
              malformed!
            end
          end

          def malformed!
            raise Hive::ConfigError,
                  "patrol qualification scenario actuals are malformed"
          end
        end

        def initialize(payload)
          @payload = payload
          freeze
        end

        def to_h = payload
        def actuals = payload.fetch("actuals")
      end
    end
  end
end
