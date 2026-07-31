require "json"
require "pathname"
require "hive/errors"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Canonical candidate-process request. It carries only descriptor-bound
      # stimulus identity and workspace-relative paths; qualification
      # expectations remain host-side.
      class QualificationScenarioRequest
        SCHEMA =
          "hive-patrol-qualification-scenario-request".freeze
        SCHEMA_VERSION = 1
        MAX_BYTES = 64 * 1024
        MAX_REF_BYTES = 1024
        MAX_REF_DEPTH = 16
        MAX_GENERATION = 3
        STOP_AFTER = %w[
          after_effect_intent after_legacy_capture after_legacy_decision
          after_module_decision before_effect_settlement
          during_reconciliation reconciliation_failure
        ].freeze
        KEYS = %w[
          case_id generation output_ref package_root_ref project
          sandbox_root_ref scenario_ref scenario_sha256 schema
          schema_version stop_after
        ].freeze

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

          def canonical(value)
            Hive::WorkflowPackage::CanonicalJSON.generate(value)
          end

          private

          def validate(value)
            exact!(value, KEYS)
            malformed! unless
              value["schema"] == SCHEMA &&
                value["schema_version"] == SCHEMA_VERSION &&
                QualificationRunDescriptor::SAFE_ID.match?(
                  value["case_id"].to_s
                ) &&
                QualificationRunDescriptor::DIGEST.match?(
                  value["scenario_sha256"].to_s
                ) &&
                value["generation"].is_a?(Integer) &&
                value["generation"].between?(1, MAX_GENERATION) &&
                (
                  value["stop_after"].nil? ||
                    STOP_AFTER.include?(value["stop_after"])
                )
            project = value["project"]
            exact!(
              project,
              QualificationRunDescriptor::PROJECT_KEYS
            )
            malformed! unless
              QualificationRunDescriptor::PROJECT_KEYS.all? do |key|
                child = project[key]
                child.is_a?(String) &&
                  !child.empty? &&
                  child.bytesize <= 512 &&
                  !child.match?(/[\u0000-\u001f\u007f]/)
              end &&
                QualificationRunDescriptor::REPOSITORY.match?(
                  project["repository"].to_s
                )
            refs = %w[
              output_ref package_root_ref sandbox_root_ref scenario_ref
            ].to_h do |key|
              [ key, relative_ref!(value[key]) ]
            end
            malformed! unless
              refs.values.uniq.length == refs.values.length &&
                refs.fetch("scenario_ref")
                  .start_with?("inputs/scenarios/") &&
                refs.fetch("scenario_ref").end_with?(".yml") &&
                refs.fetch("package_root_ref") ==
                  "targets/candidate" &&
                refs.fetch("sandbox_root_ref") ==
                  "cases/#{value.fetch('case_id')}/sandbox" &&
                refs.fetch("output_ref") ==
                  "cases/#{value.fetch('case_id')}/generations/" \
                  "#{value.fetch('generation')}/output/" \
                  "scenario-actuals.json"
            immutable(value.merge(refs))
          rescue ArgumentError, KeyError, NoMethodError, TypeError
            malformed!
          end

          def relative_ref!(value)
            malformed! unless
              value.is_a?(String) &&
                !value.empty? &&
                value.bytesize <= MAX_REF_BYTES &&
                !value.start_with?("/") &&
                !value.include?("\\") &&
                !value.include?("\0")
            parts = value.split("/", -1)
            malformed! unless
              parts.length <= MAX_REF_DEPTH &&
                parts.none? do |part|
                  part.empty? || part == "." || part == ".."
                end
            value
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
                  "patrol qualification scenario request is malformed"
          end
        end

        def initialize(payload)
          @payload = payload
          freeze
        end

        def to_h = payload
        def case_id = payload.fetch("case_id")
        def generation = payload.fetch("generation")
        def stop_after = payload.fetch("stop_after")
        def scenario_sha256 = payload.fetch("scenario_sha256")
        def scenario_ref = payload.fetch("scenario_ref")
        def package_root_ref = payload.fetch("package_root_ref")
        def sandbox_root_ref = payload.fetch("sandbox_root_ref")
        def output_ref = payload.fetch("output_ref")
        def project = payload.fetch("project")

        def resolve(root, relative)
          expanded_root = File.expand_path(root)
          stat = File.lstat(expanded_root)
          unless
            stat.directory? &&
              !stat.symlink? &&
              File.realpath(expanded_root) == expanded_root
            raise Hive::ConfigError,
                  "patrol qualification scenario workspace is unsafe"
          end
          relative = self.class.send(:relative_ref!, relative)
          path = File.expand_path(relative, expanded_root)
          unless path.start_with?(
            "#{expanded_root}#{File::SEPARATOR}"
          )
            raise Hive::ConfigError,
                  "patrol qualification scenario workspace is unsafe"
          end
          path.freeze
        rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR,
               Errno::ELOOP, ArgumentError
          raise Hive::ConfigError,
                "patrol qualification scenario workspace is unsafe"
        end
      end
    end
  end
end
