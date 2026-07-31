require "digest"
require "json"
require "time"
require "hive/errors"
require "hive/modules/migration/trusted_qualification_control"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Canonical, immutable authority for exactly one Patrol qualification
      # run. Identity excludes the two identity fields; descriptor_sha256 then
      # seals the complete document including that derived run_id.
      class QualificationRunDescriptor
        SCHEMA = "hive-patrol-qualification-run".freeze
        SCHEMA_VERSION = 1
        MAX_BYTES = 4 * 1024 * 1024
        LANES = %w[deterministic installed].freeze
        MODULES = %w[architecture-patrol patrol].freeze
        TOP_LEVEL_KEYS = %w[
          artifact_refs candidate control descriptor_sha256 expectations
          lanes module_selections prepared_at project run_id scenarios
          schema schema_version
        ].freeze
        CANDIDATE_KEYS = %w[
          artifact_manifest_sha256 candidate_gem_sha256 commit_sha
          installed_tree_sha256 skills_archive_sha256 source_archive_sha256
        ].freeze
        PROJECT_KEYS = %w[name project_id repository].freeze
        SELECTION_KEYS = %w[active selection_epoch].freeze
        ACTIVE_KEYS = %w[
          catalog_commit configuration_digest manifest_digest source_commit
          version
        ].freeze
        SCENARIO_KEYS = %w[cases manifest_ref manifest_sha256].freeze
        CASE_KEYS = %w[
          case_id decision_expectations expected_legacy_effect_keys faults
          matrix scenario_ref scenario_sha256
        ].freeze
        EXPECTATION_KEYS = %w[
          decision_expectations expected_legacy_effect_keys required_faults
          required_matrix
        ].freeze
        DECISION_KEYS = %w[
          control decision_class decision_id module repository repository_sha
          trigger_digest
        ].freeze
        LANE_KEYS = %w[
          credential_bindings executable kind model network provider
          repository_sha target_ref timeout_seconds
        ].freeze
        ARTIFACT_KEYS = %w[
          artifacts bundle repro_json repro_script result
        ].freeze
        CONTROLS = %w[
          architecture_positive_thesis clean_negative
          ordinary_positive_finding none
        ].freeze
        REQUIRED_FAULTS = %w[
          after_effect_intent after_legacy_capture after_legacy_decision
          after_module_decision during_reconciliation
        ].freeze
        INSTALLED_CREDENTIAL_BINDINGS = %w[
          OPENROUTER_API_KEY
        ].freeze
        DETERMINISTIC_MODEL = "qualification-fixture".freeze
        INSTALLED_MODEL = "openai/gpt-5.6-terra".freeze
        RUN_ID = /\Apatrol-[0-9a-f]{64}\z/
        SHA = /\A[0-9a-f]{40}\z/
        DIGEST = /\A[0-9a-f]{64}\z/
        EFFECT = /\Aeffect-[0-9a-f]{64}\z/
        SAFE_ID = /\A[a-z0-9][a-z0-9._-]{0,127}\z/
        REPOSITORY = %r{
          \Agithub\.com/
          [a-z0-9][a-z0-9._-]{0,99}/
          [a-z0-9][a-z0-9._-]{0,99}\z
        }x

        attr_reader :payload

        class << self
          def load(bytes)
            unless bytes.is_a?(String) &&
                   bytes.bytesize <= MAX_BYTES
              malformed!
            end
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
            exact!(value, TOP_LEVEL_KEYS)
            malformed! unless value["schema"] == SCHEMA &&
                              value["schema_version"] ==
                                SCHEMA_VERSION
            exact_timestamp!(value["prepared_at"])
            repository =
              validate_project(value.fetch("project"))
            validate_selections(value.fetch("module_selections"))
            validate_candidate(value.fetch("candidate"))
            TrustedQualificationControl.normalize(
              value.fetch("control")
            )
            validate_scenarios(
              value.fetch("scenarios"),
              value.fetch("expectations"),
              repository: repository
            )
            validate_lanes(value.fetch("lanes"))
            validate_artifact_refs(value.fetch("artifact_refs"))
            validate_identity(value)
            immutable(value)
          rescue ArgumentError, KeyError, NoMethodError, TypeError
            malformed!
          end

          def validate_project(value)
            exact!(value, PROJECT_KEYS)
            PROJECT_KEYS.each { |key| nonempty!(value[key]) }
            malformed! unless
              REPOSITORY.match?(value["repository"])
            value.fetch("repository")
          end

          def validate_selections(value)
            exact!(value, MODULES)
            value.each_value do |selection|
              exact!(selection, SELECTION_KEYS)
              epoch = Integer(selection["selection_epoch"])
              malformed! unless epoch.positive?
              active = selection.fetch("active")
              exact!(active, ACTIVE_KEYS)
              nonempty!(active["version"])
              %w[catalog_commit source_commit].each do |key|
                malformed! unless SHA.match?(active[key].to_s)
              end
              %w[manifest_digest configuration_digest].each do |key|
                digest!(active[key])
              end
            end
          end

          def validate_candidate(value)
            exact!(value, CANDIDATE_KEYS)
            malformed! unless SHA.match?(value["commit_sha"].to_s)
            (CANDIDATE_KEYS - [ "commit_sha" ]).each do |key|
              digest!(value[key])
            end
          end

          def validate_scenarios(value, expectations, repository:)
            exact!(value, SCENARIO_KEYS)
            ref!(
              value["manifest_ref"],
              prefix: "inputs/scenarios/",
              suffix: ".json"
            )
            digest!(value["manifest_sha256"])
            cases = value["cases"]
            malformed! unless cases.is_a?(Array) && !cases.empty?
            ids = cases.map do |row|
              exact!(row, CASE_KEYS)
              id = safe_id!(row["case_id"])
              ref!(
                row["scenario_ref"],
                prefix: "inputs/scenarios/",
                suffix: ".yml"
              )
              digest!(row["scenario_sha256"])
              validate_decisions(
                row["decision_expectations"],
                repository: repository
              )
              validate_effects(
                row["expected_legacy_effect_keys"],
                empty: true
              )
              strings!(row["matrix"])
              faults!(row["faults"], empty: true)
              id
            end
            malformed! unless ids.uniq.length == ids.length

            exact!(expectations, EXPECTATION_KEYS)
            validate_decisions(
              expectations["decision_expectations"],
              repository: repository
            )
            validate_effects(
              expectations["expected_legacy_effect_keys"]
            )
            strings!(expectations["required_matrix"])
            faults!(expectations["required_faults"])
            case_decisions = cases.flat_map do |row|
              row["decision_expectations"]
            end
            malformed! unless
              case_decisions.map do |row|
                row.fetch("decision_id")
              end.uniq.length == case_decisions.length
            expected_decisions = case_decisions.sort_by do |row|
              row.fetch("decision_id")
            end
            expected_effects = cases.flat_map do |row|
              row["expected_legacy_effect_keys"]
            end.uniq.sort
            expected_matrix =
              cases.flat_map { |row| row["matrix"] }.uniq.sort
            expected_faults =
              cases.flat_map { |row| row["faults"] }.uniq.sort
            malformed! unless
              expectations["decision_expectations"] ==
                expected_decisions &&
              expectations["expected_legacy_effect_keys"] ==
                expected_effects &&
              expectations["required_matrix"] == expected_matrix &&
              expectations["required_faults"] == expected_faults
          end

          def validate_decisions(value, repository:)
            malformed! unless
              value.is_a?(Array) && !value.empty?
            value.each do |row|
              exact!(row, DECISION_KEYS)
              digest!(row["decision_id"])
              malformed! unless MODULES.include?(row["module"])
              nonempty!(row["decision_class"])
              malformed! unless
                row["repository"] == repository
              malformed! unless
                SHA.match?(row["repository_sha"].to_s)
              digest!(row["trigger_digest"])
              malformed! unless CONTROLS.include?(row["control"])
            end
            malformed! unless
              value.map { |row| row["decision_id"] }.uniq.length ==
                value.length &&
              value == value.sort_by do |row|
                row.fetch("decision_id")
              end
          end

          def validate_effects(value, empty: false)
            malformed! unless
              value.is_a?(Array) &&
              (empty || !value.empty?) &&
              value.uniq.length == value.length &&
              value == value.sort &&
              value.all? { |key| EFFECT.match?(key.to_s) }
          end

          def strings!(value, empty: false)
            malformed! unless
              value.is_a?(Array) &&
              (empty || !value.empty?) &&
              value.all? do |item|
                item.is_a?(String) && !item.empty?
              end &&
              value.uniq.length == value.length &&
              value == value.sort
          end

          def faults!(value, empty: false)
            strings!(value, empty: empty)
            malformed! unless (value - REQUIRED_FAULTS).empty?
          end

          def validate_lanes(value)
            exact!(value, LANES)
            value.each do |lane, policy|
              exact!(policy, LANE_KEYS)
              expected_kind = lane == "deterministic" ?
                "source_archive" : "installed_target"
              malformed! unless policy["kind"] == expected_kind
              timeout = Integer(policy["timeout_seconds"])
              malformed! unless timeout.between?(1, 3_600)
              relative!(policy["executable"])
              if lane == "deterministic"
                malformed! unless
                  policy["network"] == false &&
                  policy["provider"] == "fixture" &&
                  policy["model"] == DETERMINISTIC_MODEL &&
                  SHA.match?(policy["repository_sha"].to_s) &&
                  policy["credential_bindings"] == []
                ref!(
                  policy["target_ref"],
                  prefix: "inputs/candidate/",
                  suffix: ".tar.gz"
                )
              else
                malformed! unless
                  policy["target_ref"] ==
                    "inputs/installed-target/target.json" &&
                  policy["network"] == false &&
                  policy["provider"] == "openrouter" &&
                  policy["model"] == INSTALLED_MODEL &&
                  SHA.match?(policy["repository_sha"].to_s)
                credentials = policy["credential_bindings"]
                malformed! unless
                  credentials ==
                    INSTALLED_CREDENTIAL_BINDINGS
              end
            end
          end

          def validate_artifact_refs(value)
            exact!(value, LANES)
            value.each do |lane, refs|
              exact!(refs, ARTIFACT_KEYS)
              expected = {
                "result" => "lanes/#{lane}/result.json",
                "bundle" => "lanes/#{lane}/bundle.json",
                "artifacts" => "lanes/#{lane}/artifacts",
                "repro_json" => "lanes/#{lane}/repro.json",
                "repro_script" => "lanes/#{lane}/repro.sh"
              }
              malformed! unless refs == expected
            end
          end

          def validate_identity(value)
            identity = value.reject do |key, _item|
              %w[run_id descriptor_sha256].include?(key)
            end
            expected_run =
              "patrol-#{Digest::SHA256.hexdigest(canonical(identity))}"
            malformed! unless value["run_id"] == expected_run &&
                              RUN_ID.match?(value["run_id"].to_s)
            descriptor = value.reject do |key, _item|
              key == "descriptor_sha256"
            end
            malformed! unless
              value["descriptor_sha256"] ==
                Digest::SHA256.hexdigest(canonical(descriptor))
          end

          def exact!(value, keys)
            malformed! unless value.is_a?(Hash) &&
                              value.keys.sort == keys.sort
          end

          def ref!(value, prefix:, suffix:)
            relative!(value)
            malformed! unless value.start_with?(prefix) &&
                              value.end_with?(suffix)
          end

          def relative!(value)
            malformed! unless value.is_a?(String) && !value.empty? &&
                              !value.start_with?("/") &&
                              !value.include?("\\") &&
                              value.split("/").none? do |part|
                                part.empty? || part == "." || part == ".."
                              end
          end

          def safe_id!(value)
            text = value.to_s
            malformed! unless SAFE_ID.match?(text)
            text
          end

          def nonempty!(value)
            malformed! unless value.is_a?(String) && !value.empty?
          end

          def digest!(value)
            malformed! unless DIGEST.match?(value.to_s)
          end

          def exact_timestamp!(value)
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
                  "patrol qualification run descriptor is malformed"
          end
        end

        def initialize(payload)
          @payload = payload
          freeze
        end

        def run_id = payload.fetch("run_id")
        def candidate = payload.fetch("candidate")
        def control = payload.fetch("control")
        def project = payload.fetch("project")
        def module_selections = payload.fetch("module_selections")
        def scenarios = payload.fetch("scenarios")
        def expectations = payload.fetch("expectations")
        def lane_policy(lane)
          payload.fetch("lanes").fetch(lane.to_s)
        rescue KeyError
          raise Hive::ConfigError,
                "patrol qualification evidence lane is malformed"
        end

        def artifact_refs(lane)
          payload.fetch("artifact_refs").fetch(lane.to_s)
        rescue KeyError
          raise Hive::ConfigError,
                "patrol qualification evidence lane is malformed"
        end

        def authority_for(lane)
          lane = lane.to_s
          policy = lane_policy(lane)
          {
            "run_id" => run_id,
            "lane" => lane,
            "project" => project,
            "module_selections" => module_selections,
            "candidate" => candidate,
            "control" => control,
            "scenario_manifest_digest" =>
              scenarios.fetch("manifest_sha256"),
            "decision_expectations" =>
              expectations.fetch("decision_expectations"),
            "expected_legacy_effect_keys" =>
              expectations.fetch(
                "expected_legacy_effect_keys"
              ),
            "required_matrix" =>
              expectations.fetch("required_matrix"),
            "required_faults" =>
              expectations.fetch("required_faults"),
            "lane_policy" => policy,
            "artifact_refs" => artifact_refs(lane)
          }.freeze
        end
      end
    end
  end
end
