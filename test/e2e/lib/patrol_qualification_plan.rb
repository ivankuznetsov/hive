require "digest"
require "json"
require "open3"
require "pathname"
require "time"
require "hive/errors"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/modules/migration/qualification_harness_manifest"
require "hive/modules/migration/qualification_scenario_input"
require "hive/modules/migration/trusted_qualification_control"
require "hive/workflow_package/canonical_json"

module Hive
  module E2E
    # Trusted harness-side compiler for one immutable Patrol qualification run.
    #
    # The committed catalog owns expected outcomes. Candidate processes receive
    # only the referenced scenario YAML; they never receive this catalog or the
    # descriptor's decision/effect expectations.
    class PatrolQualificationPlan
      CATALOG_SCHEMA =
        "hive-patrol-qualification-catalog".freeze
      CATALOG_VERSION = 1
      CATALOG_KEYS = %w[
        cases lanes module_selections project schema schema_version
      ].freeze
      CASE_KEYS = %w[
        case_id decision_expectations expected_legacy_effect_keys
        faults file matrix module operation
      ].freeze
      LANE_KEYS =
        Hive::Modules::Migration::
          QualificationRunDescriptor::LANES.freeze
      LANE_POLICY_KEYS = %w[
        repository_sha timeout_seconds
      ].freeze
      MAX_CATALOG_BYTES = 4 * 1024 * 1024
      SAFE_REPOSITORY_REF =
        %r{\A[a-zA-Z0-9][a-zA-Z0-9._/-]{0,4095}\z}
      DEFAULT_CATALOG_REF =
        "test/e2e/fixtures/patrol_qualification/catalog.json".freeze

      Result = Data.define(
        :run_id, :descriptor_bytes, :inputs
      )

      class CommittedReader
        def read(control:, ref:)
          unless
            control.is_a?(
              Hive::Modules::Migration::
                TrustedQualificationControl
            )
            raise Hive::ConfigError,
                  "patrol qualification committed input is malformed"
          end
          root = control.checkout_root
          commit_sha =
            control.payload.fetch("commit_sha")
          unless
            commit_sha.match?(/\A[0-9a-f]{40}\z/) &&
              safe_ref?(ref)
            raise Hive::ConfigError,
                  "patrol qualification committed input is malformed"
          end
          verify_control_identity!(control)
          mode_output, mode_error, mode_status =
            Open3.capture3(
              "git", "ls-tree", commit_sha, "--", ref,
              chdir: root
            )
          mode, type, object, path =
            mode_output.strip.split(/\s+/, 4)
          unless
            mode_status.success? &&
              mode == "100644" &&
              type == "blob" &&
              object.to_s.match?(/\A[0-9a-f]{40,64}\z/) &&
              path == ref
            detail =
              mode_error.strip.empty? ?
                "not a committed regular file" :
                mode_error.strip
            raise Hive::ConfigError,
                  "patrol qualification committed input is unavailable: " \
                  "#{detail}"
          end
          output, error, status =
            Open3.capture3(
              "git", "show", "#{commit_sha}:#{ref}",
              chdir: root
            )
          unless status.success?
            raise Hive::ConfigError,
                  "patrol qualification committed input is unavailable: " \
                  "#{error.strip}"
          end
          output.b.freeze
        rescue Errno::ENOENT, Errno::EACCES,
               Errno::ENOTDIR => error
          raise Hive::ConfigError,
                "patrol qualification committed input is unavailable: " \
                "#{error.class}"
        end

        private

        def verify_control_identity!(control)
          payload = control.payload
          root = control.checkout_root
          commit_sha = payload.fetch("commit_sha")
          tree, tree_error, tree_status =
            Open3.capture3(
              "git", "rev-parse", "#{commit_sha}^{tree}",
              chdir: root
            )
          ancestor_ok = true
          if control.trusted_remote?
            ancestor_ok =
              Open3.capture3(
                "git", "merge-base", "--is-ancestor",
                commit_sha, payload.fetch("ref"),
                chdir: root
              ).fetch(2).success?
          end
          unless
            tree_status.success? &&
              tree.strip == payload.fetch("tree_sha") &&
              ancestor_ok
            detail =
              tree_error.strip.empty? ?
                "identity mismatch" :
                tree_error.strip
            raise Hive::ConfigError,
                  "patrol qualification committed input is unavailable: " \
                  "#{detail}"
          end
        end

        def safe_ref?(value)
          return false unless value.is_a?(String)

          path = Pathname.new(value)
          SAFE_REPOSITORY_REF.match?(value) &&
            !path.absolute? &&
            path.cleanpath.to_s == value &&
            !value.include?("\\") &&
            !value.include?("\0") &&
            value.split("/").none? do |part|
              part.empty? || part == "." || part == ".."
            end
        rescue ArgumentError
          false
        end
      end

      def initialize(
        clock: -> { Time.now.utc },
        committed_reader: CommittedReader.new,
        harness_verifier:
          Hive::Modules::Migration::QualificationHarnessManifest
      )
        @clock = clock
        @committed_reader = committed_reader
        @harness_verifier = harness_verifier
      end

      def call(
        candidate:, control:
      )
        unless
          control.is_a?(
            Hive::Modules::Migration::
              TrustedQualificationControl
          )
          malformed!
        end
        @harness_verifier.verify!(control: control)
        catalog_ref =
          control.payload.dig("catalog", "ref")
        catalog_root, catalog =
          load_catalog(
            control: control,
            catalog_ref: catalog_ref
          )
        candidate_manifest =
          canonical_json(
            candidate.manifest_bytes,
            "candidate manifest"
          )
        scenarios, scenario_inputs =
          load_scenarios(
            control: control,
            catalog_root: catalog_root,
            cases: catalog.fetch("cases")
          )
        scenario_manifest = canonical(
          "cases" => scenarios.map do |row|
            row.slice("case_id", "path", "sha256")
          end
        )
        payload = descriptor_payload(
          candidate: candidate,
          control: control,
          candidate_manifest: candidate_manifest,
          catalog: catalog,
          scenarios: scenarios,
          scenario_manifest: scenario_manifest
        )
        seal!(payload)
        descriptor_bytes = canonical(payload)
        descriptor =
          Hive::Modules::Migration::
            QualificationRunDescriptor.load(descriptor_bytes)
        inputs = normalize_candidate_inputs(candidate.inputs)
          .merge(scenario_inputs)
          .merge(
            "inputs/scenarios/manifest.json" => {
              bytes: scenario_manifest,
              mode: 0o600
            }.freeze
          )
          .freeze
        Result.new(
          run_id: descriptor.run_id,
          descriptor_bytes: descriptor_bytes.freeze,
          inputs: inputs
        ).freeze
      rescue KeyError, NoMethodError, TypeError
        malformed!
      end

      private

      def load_catalog(control:, catalog_ref:)
        unless safe_repository_ref?(catalog_ref)
          malformed!
        end
        bytes = @committed_reader.read(
          control: control,
          ref: catalog_ref
        )
        malformed! if bytes.bytesize > MAX_CATALOG_BYTES
        unless
          Digest::SHA256.hexdigest(bytes) ==
            control.payload.dig("catalog", "sha256")
          malformed!
        end
        catalog = canonical_json(bytes, "catalog")
        exact!(catalog, CATALOG_KEYS)
        unless
          catalog["schema"] == CATALOG_SCHEMA &&
            catalog["schema_version"] == CATALOG_VERSION
          malformed!
        end
        validate_project!(catalog.fetch("project"))
        validate_lanes!(catalog.fetch("lanes"))
        validate_module_selections!(
          catalog.fetch("module_selections")
        )
        cases = catalog.fetch("cases")
        unless cases.is_a?(Array) && !cases.empty?
          malformed!
        end
        ids = cases.map do |row|
          exact!(row, CASE_KEYS)
          validate_case!(row)
          row.fetch("case_id")
        end
        malformed! unless ids.uniq.length == ids.length
        [
          File.dirname(catalog_ref).freeze,
          catalog.freeze
        ].freeze
      rescue JSON::ParserError, EncodingError
        malformed!
      end

      def validate_project!(value)
        descriptor =
          Hive::Modules::Migration::
            QualificationRunDescriptor
        exact!(value, descriptor::PROJECT_KEYS)
        unless
          value.values.all? do |child|
            child.is_a?(String) && !child.empty?
          end &&
            descriptor::REPOSITORY.match?(
              value.fetch("repository")
            )
          malformed!
        end
      end

      def validate_lanes!(value)
        exact!(value, LANE_KEYS)
        value.each_value do |policy|
          exact!(policy, LANE_POLICY_KEYS)
          unless
            full_sha?(policy.fetch("repository_sha")) &&
              Integer(policy.fetch("timeout_seconds"))
                .between?(1, 3_600)
            malformed!
          end
        end
      rescue ArgumentError, TypeError
        malformed!
      end

      def validate_module_selections!(value)
        descriptor =
          Hive::Modules::Migration::
            QualificationRunDescriptor
        exact!(value, descriptor::MODULES)
        value.each_value do |selection|
          exact!(selection, descriptor::SELECTION_KEYS)
          unless
            Integer(selection.fetch("selection_epoch")).positive?
            malformed!
          end
          active = selection.fetch("active")
          exact!(active, descriptor::ACTIVE_KEYS)
          unless
            !active.fetch("version").to_s.empty? &&
              full_sha?(active.fetch("catalog_commit")) &&
              full_sha?(active.fetch("source_commit")) &&
              digest?(active.fetch("manifest_digest")) &&
              digest?(active.fetch("configuration_digest"))
            malformed!
          end
        end
      rescue ArgumentError, TypeError
        malformed!
      end

      def validate_case!(row)
        descriptor =
          Hive::Modules::Migration::
            QualificationRunDescriptor
        unless
          descriptor::SAFE_ID.match?(row.fetch("case_id").to_s) &&
            descriptor::MODULES.include?(row.fetch("module")) &&
            Hive::Modules::Migration::
              QualificationScenarioInput::OPERATIONS.include?(
                row.fetch("operation")
              ) &&
            safe_scenario_file?(row.fetch("file")) &&
            string_set?(row.fetch("matrix")) &&
            string_set?(row.fetch("faults"), empty: true) &&
            (
              row.fetch("faults") -
                descriptor::REQUIRED_FAULTS
            ).empty? &&
            row.fetch("decision_expectations").is_a?(Array) &&
            !row.fetch("decision_expectations").empty? &&
            row.fetch("expected_legacy_effect_keys").is_a?(Array)
          malformed!
        end
      end

      def load_scenarios(
        control:, catalog_root:, cases:
      )
        rows = []
        inputs = {}
        cases.each do |catalog_row|
          file = catalog_row.fetch("file")
          ref = File.join(catalog_root, file)
          malformed! unless safe_repository_ref?(ref)
          bytes = @committed_reader.read(
            control: control,
            ref: ref
          )
          scenario =
            Hive::Modules::Migration::
              QualificationScenarioInput.load(
                bytes,
                expected_case_id:
                  catalog_row.fetch("case_id")
              )
          unless
            scenario.module_name ==
              catalog_row.fetch("module") &&
              scenario.operation ==
                catalog_row.fetch("operation") &&
              scenario.faults ==
                catalog_row.fetch("faults")
            malformed!
          end
          ref =
            "inputs/scenarios/" \
            "#{catalog_row.fetch('case_id')}.yml"
          sha256 = Digest::SHA256.hexdigest(bytes)
          rows << {
            "case_id" => catalog_row.fetch("case_id"),
            "scenario_ref" => ref,
            "scenario_sha256" => sha256,
            "decision_expectations" =>
              catalog_row.fetch("decision_expectations"),
            "expected_legacy_effect_keys" =>
              catalog_row.fetch("expected_legacy_effect_keys"),
            "matrix" => catalog_row.fetch("matrix"),
            "faults" => catalog_row.fetch("faults"),
            "path" => ref,
            "sha256" => sha256
          }.freeze
          inputs[ref] = {
            bytes: bytes.freeze,
            mode: 0o600
          }.freeze
        end
        [
          rows.sort_by { |row| row.fetch("case_id") }.freeze,
          inputs.freeze
        ].freeze
      end

      def descriptor_payload(
        candidate:, control:, candidate_manifest:, catalog:,
        scenarios:, scenario_manifest:
      )
        source_name = artifact_name(
          candidate_manifest, "source"
        )
        decisions =
          scenarios.flat_map do |row|
            row.fetch("decision_expectations")
          end.sort_by { |row| row.fetch("decision_id") }
        effects =
          scenarios.flat_map do |row|
            row.fetch("expected_legacy_effect_keys")
          end.uniq.sort
        matrix =
          scenarios.flat_map { |row| row.fetch("matrix") }
            .uniq.sort
        faults =
          scenarios.flat_map { |row| row.fetch("faults") }
            .uniq.sort
        descriptor_cases = scenarios.map do |row|
          row.slice(
            "case_id",
            "scenario_ref",
            "scenario_sha256",
            "decision_expectations",
            "expected_legacy_effect_keys",
            "matrix",
            "faults"
          )
        end
        {
          "schema" =>
            Hive::Modules::Migration::
              QualificationRunDescriptor::SCHEMA,
          "schema_version" =>
            Hive::Modules::Migration::
              QualificationRunDescriptor::SCHEMA_VERSION,
          "run_id" => nil,
          "descriptor_sha256" => nil,
          "prepared_at" => utc_time(@clock.call).iso8601(6),
          "project" => catalog.fetch("project"),
          "module_selections" =>
            catalog.fetch("module_selections"),
          "candidate" => {
            "commit_sha" => candidate.candidate_sha,
            "artifact_manifest_sha256" =>
              candidate.digests.fetch(
                "artifact_manifest_sha256"
              ),
            "source_archive_sha256" =>
              candidate.digests.fetch(
                "source_archive_sha256"
              ),
            "candidate_gem_sha256" =>
              candidate.digests.fetch(
                "candidate_gem_sha256"
              ),
            "skills_archive_sha256" =>
              candidate.digests.fetch(
                "skills_archive_sha256"
              ),
            "installed_tree_sha256" =>
              candidate.digests.fetch(
                "installed_tree_sha256"
              )
          },
          "control" => control.payload,
          "scenarios" => {
            "manifest_ref" =>
              "inputs/scenarios/manifest.json",
            "manifest_sha256" =>
              Digest::SHA256.hexdigest(scenario_manifest),
            "cases" => descriptor_cases
          },
          "expectations" => {
            "decision_expectations" => decisions,
            "expected_legacy_effect_keys" => effects,
            "required_matrix" => matrix,
            "required_faults" => faults
          },
          "lanes" => lane_policies(
            catalog.fetch("lanes"),
            source_name: source_name
          ),
          "artifact_refs" =>
            Hive::Modules::Migration::
              QualificationRunDescriptor::LANES.to_h do |lane|
                [
                  lane,
                  {
                    "result" =>
                      "lanes/#{lane}/result.json",
                    "bundle" =>
                      "lanes/#{lane}/bundle.json",
                    "artifacts" =>
                      "lanes/#{lane}/artifacts",
                    "repro_json" =>
                      "lanes/#{lane}/repro.json",
                    "repro_script" =>
                      "lanes/#{lane}/repro.sh"
                  }
                ]
              end
        }
      end

      def lane_policies(value, source_name:)
        deterministic = value.fetch("deterministic")
        installed = value.fetch("installed")
        {
          "deterministic" => {
            "credential_bindings" => [],
            "kind" => "source_archive",
            "provider" => "fixture",
            "model" =>
              Hive::Modules::Migration::
                QualificationRunDescriptor::
                  DETERMINISTIC_MODEL,
            "repository_sha" =>
              deterministic.fetch("repository_sha"),
            "target_ref" =>
              "inputs/candidate/#{source_name}",
            "executable" => "bin/hive",
            "network" => false,
            "timeout_seconds" =>
              deterministic.fetch("timeout_seconds")
          },
          "installed" => {
            "credential_bindings" =>
              Hive::Modules::Migration::
                QualificationRunDescriptor::
                  INSTALLED_CREDENTIAL_BINDINGS,
            "kind" => "installed_target",
            "provider" => "openrouter",
            "model" =>
              Hive::Modules::Migration::
                QualificationRunDescriptor::
                  INSTALLED_MODEL,
            "repository_sha" =>
              installed.fetch("repository_sha"),
            "target_ref" =>
              "inputs/installed-target/target.json",
            "executable" => "bin/hive",
            "network" => false,
            "timeout_seconds" =>
              installed.fetch("timeout_seconds")
          }
        }.freeze
      end

      def artifact_name(manifest, kind)
        matches = manifest.fetch("files").select do |_name, row|
          row.is_a?(Hash) && row["kind"] == kind
        end
        unless matches.length == 1
          malformed!
        end
        matches.keys.fetch(0)
      end

      def normalize_candidate_inputs(value)
        unless value.is_a?(Hash) && !value.empty?
          malformed!
        end
        value.to_h do |ref, snapshot|
          unless
            ref.is_a?(String) &&
              ref.start_with?("inputs/") &&
              snapshot.is_a?(Hash) &&
              snapshot.keys.sort == %i[bytes mode] &&
              snapshot.fetch(:bytes).is_a?(String) &&
              [ 0o600, 0o700 ].include?(
                snapshot.fetch(:mode)
              )
            malformed!
          end
          [
            ref.freeze,
            {
              bytes: snapshot.fetch(:bytes).dup.freeze,
              mode: snapshot.fetch(:mode)
            }.freeze
          ]
        end.freeze
      end

      def seal!(payload)
        identity = payload.reject do |key, _value|
          %w[run_id descriptor_sha256].include?(key)
        end
        payload["run_id"] =
          "patrol-#{Digest::SHA256.hexdigest(canonical(identity))}"
        descriptor = payload.reject do |key, _value|
          key == "descriptor_sha256"
        end
        payload["descriptor_sha256"] =
          Digest::SHA256.hexdigest(canonical(descriptor))
        payload
      end

      def canonical_json(bytes, _label)
        unless bytes.is_a?(String)
          malformed!
        end
        value = JSON.parse(bytes)
        malformed! unless bytes == canonical(value)
        value
      end

      def canonical(value)
        Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end

      def exact!(value, keys)
        unless
          value.is_a?(Hash) &&
            value.keys.all? { |key| key.is_a?(String) } &&
            value.keys.sort == keys.sort
          malformed!
        end
      end

      def safe_scenario_file?(value)
        return false unless value.is_a?(String)

        path = Pathname.new(value)
        SAFE_REPOSITORY_REF.match?(value) &&
          !path.absolute? &&
          path.cleanpath.to_s == value &&
          value.end_with?(".yml") &&
          !value.include?("\\") &&
          value.split("/").none? do |part|
            part.empty? || part == "." || part == ".."
          end
      rescue ArgumentError
        false
      end

      def safe_repository_ref?(value)
        return false unless value.is_a?(String)

        path = Pathname.new(value)
        !path.absolute? &&
          path.cleanpath.to_s == value &&
          !value.include?("\\") &&
          !value.include?("\0") &&
          value.split("/").none? do |part|
            part.empty? || part == "." || part == ".."
          end
      rescue ArgumentError
        false
      end

      def string_set?(value, empty: false)
        value.is_a?(Array) &&
          (empty || !value.empty?) &&
          value.all? do |item|
            item.is_a?(String) && !item.empty?
          end &&
          value.uniq.length == value.length &&
          value == value.sort
      end

      def full_sha?(value)
        Hive::Modules::Migration::
          QualificationRunDescriptor::SHA.match?(value.to_s)
      end

      def digest?(value)
        Hive::Modules::Migration::
          QualificationRunDescriptor::DIGEST.match?(value.to_s)
      end

      def utc_time(value)
        value.is_a?(Time) ?
          value.utc : Time.iso8601(value.to_s).utc
      rescue ArgumentError
        malformed!
      end

      def malformed!
        raise Hive::ConfigError,
              "patrol qualification catalog is malformed"
      end
    end
  end
end
