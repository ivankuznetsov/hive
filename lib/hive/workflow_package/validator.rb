require "digest"
require "rubygems/version"
require "set"
require "yaml"
require "hive/workflow_package/manifest"
require "hive/workflow_package/permission_projection"
require "hive/workflow_package/registry_manifest"
require "hive/workflow_package/runtime_policy"
require "hive/workflow_package/security_scanner"
require "hive/workflow_package/configuration"
require "hive/workflow_package/input_name"
require "hive/workflows/descriptor_parser"

module Hive
  module WorkflowPackage
    class Validator
      Result = Data.define(:manifest, :workflow, :manifest_digest, :diagnostics) do
        def valid? = errors.empty?
        def errors = diagnostics.select(&:error?)
        def warnings = diagnostics.select(&:warning?)

        def to_h
          {
            "valid" => valid?,
            "manifest_digest" => manifest_digest,
            "diagnostics" => diagnostics.map(&:to_h)
          }
        end
      end

      def self.validate(root, expected_name: nil, expected_manifest_digest: nil, managed: true)
        new(root, expected_name: expected_name, expected_manifest_digest: expected_manifest_digest,
                  managed: managed).validate
      end

      def self.validate!(...)
        result = validate(...)
        raise PackageError, result.errors.first unless result.valid?

        result
      end

      def initialize(root, expected_name:, expected_manifest_digest:, managed:)
        @root = File.expand_path(root)
        @expected_name = expected_name&.to_s
        @expected_manifest_digest = expected_manifest_digest&.to_s
        @managed = managed
      end

      def validate
        diagnostics = []
        manifest = load_manifest
        digest = manifest.digest
        if @expected_manifest_digest && !secure_equal?(digest, @expected_manifest_digest)
          diagnostics << diagnostic("manifest.digest_mismatch", manifest.file_name,
                                    "manifest digest does not match trusted catalog or installed lock")
        end
        if @expected_name && manifest.data.fetch("name") != @expected_name
          diagnostics << diagnostic("manifest.name_mismatch", manifest.file_name,
                                    "manifest name does not match the requested package")
        end
        if manifest.is_a?(RegistryManifest) && comparable_version(Hive::VERSION) < comparable_version(manifest.data.fetch("hive_min_version"))
          diagnostics << diagnostic(
            "manifest.hive_version_unsupported", RegistryManifest::FILE_NAME,
            "package requires Hive #{manifest.data.fetch('hive_min_version')} or newer; current Hive is #{Hive::VERSION}"
          )
        end

        actual = Manifest.inventory(@root, exclude: [ Manifest::FILE_NAME, RegistryManifest::FILE_NAME ])
        expected = manifest.file_entries
        compare_inventory(expected, actual, diagnostics)
        descriptor_path = File.join(@root, manifest.descriptor)
        workflow = parse_workflow(descriptor_path, manifest.data.fetch("name"), diagnostics)
        validate_managed_workflow(workflow, diagnostics, registry: manifest.is_a?(RegistryManifest)) if workflow && @managed
        validate_permission_disclosure(manifest, workflow, diagnostics) if workflow && manifest.is_a?(RegistryManifest)
        validate_hive_extension(manifest, workflow, diagnostics) if workflow && manifest.is_a?(RegistryManifest)
        diagnostics.concat(SecurityScanner.scan_files(
          @root,
          paths: expected.map { |entry| entry.fetch("path") },
          permissions: manifest.permissions
        ))
        Result.new(manifest: manifest, workflow: workflow, manifest_digest: digest, diagnostics: diagnostics.freeze)
      rescue PackageError => e
        Result.new(manifest: nil, workflow: nil, manifest_digest: nil, diagnostics: [ e.diagnostic ].freeze)
      rescue Hive::ConfigError => e
        Result.new(manifest: nil, workflow: nil, manifest_digest: nil,
                   diagnostics: [ diagnostic("descriptor.invalid", "workflow.yml", safe_descriptor_message(e)) ].freeze)
      end

      private

      def comparable_version(version)
        Gem::Version.new(version.split("+", 2).first)
      end

      def load_manifest
        registry_path = File.join(@root, RegistryManifest::FILE_NAME)
        legacy_path = File.join(@root, Manifest::FILE_NAME)
        if File.file?(registry_path)
          raise_package_error("manifest.ambiguous", RegistryManifest::FILE_NAME,
                              "package must not contain both registry and legacy manifests") if File.exist?(legacy_path)
          RegistryManifest.load(registry_path)
        else
          Manifest.load(legacy_path)
        end
      end

      def compare_inventory(expected, actual, diagnostics)
        expected_by_path = expected.to_h { |entry| [ entry.fetch("path"), entry ] }
        actual_by_path = actual.to_h { |entry| [ entry.fetch("path"), entry ] }
        (expected_by_path.keys - actual_by_path.keys).sort.each do |path|
          diagnostics << diagnostic("manifest.missing_file", path, "manifest-listed payload file is missing")
        end
        (actual_by_path.keys - expected_by_path.keys).sort.each do |path|
          diagnostics << diagnostic("manifest.unlisted_file", path, "payload file is not listed in the manifest")
        end
        (expected_by_path.keys & actual_by_path.keys).sort.each do |path|
          expected_entry = expected_by_path.fetch(path)
          actual_entry = actual_by_path.fetch(path)
          if expected_entry.fetch("sha256") != actual_entry.fetch("sha256")
            diagnostics << diagnostic("manifest.hash_mismatch", path, "payload hash does not match the manifest")
          end
          if expected_entry.key?("size") && expected_entry.fetch("size") != actual_entry.fetch("size")
            diagnostics << diagnostic("manifest.size_mismatch", path, "payload size does not match the manifest")
          end
        end
      end

      def raise_package_error(rule, path, message)
        raise PackageError, diagnostic(rule, path, message)
      end

      def parse_workflow(path, name, diagnostics)
        Hive::Workflows::DescriptorParser.parse_package_file(path, package_name: name)
      rescue Hive::ConfigError
        diagnostics << diagnostic("descriptor.invalid", File.basename(path), "package workflow descriptor is invalid")
        nil
      end

      def validate_managed_workflow(workflow, diagnostics, registry: false)
        validate_managed_stage_contracts(workflow, diagnostics)
        workflow.executable_slots.each do |slot|
          actor = slot.actor
          if actor.permissions.nil?
            diagnostics << diagnostic(
              "policy.missing", "workflow.yml", missing_policy_message(slot.kind)
            )
          end
          if registry
            validate_actor_mapping(
              actor, actor_label(slot), diagnostics,
              required_role: slot.kind == :reviewer ? "reviewer" : nil
            )
          end
          if [ :reviewer, :revise ].include?(slot.kind) && actor.command
            diagnostics << diagnostic(
              "policy.raw_council_command", "workflow.yml", raw_command_message(slot.kind)
            )
          end
          if actor.skill && !registry
            diagnostics << diagnostic(
              "policy.external_skill", "workflow.yml", external_skill_message(slot.kind)
            )
          end
        end
      end

      # DescriptorParser rejects these shapes for every authored workflow. Keep
      # the stricter managed boundary defensive as well so a programmatically
      # constructed Workflow cannot smuggle an unknown or misplaced capability
      # into package admission.
      def validate_managed_stage_contracts(workflow, diagnostics)
        last_index = workflow.stages.length - 1
        workflow.stages.each_with_index do |stage, index|
          valid = managed_draft_pr_stage?(stage, index, last_index)
          if stage.workspace && !valid
            diagnostics << diagnostic(
              "workspace.invalid_contract", "workflow.yml",
              "stage #{stage.name} workspace must use the complete terminal draft-PR contract"
            )
          end

          next unless stage.handoff
          next if valid

          diagnostics << diagnostic(
            "handoff.invalid_contract", "workflow.yml",
            "stage #{stage.name} handoff must be draft_pr on a terminal worktree agent stage using fix-report.md"
          )
        end
      end

      def managed_draft_pr_stage?(stage, index, last_index)
        stage.workspace == :worktree && stage.handoff == :draft_pr &&
          stage.kind == :agent && index == last_index &&
          stage.state_file == "fix-report.md" && stage.deliverable == "fix-report.md"
      end

      def actor_label(slot)
        return "revise actor" if slot.kind == :revise

        "#{slot.kind} #{slot.actor.name}"
      end

      def missing_policy_message(kind)
        actor = kind == :stage ? "active stage" : kind == :revise ? "revise actor" : "reviewer"
        "every managed #{actor} must declare an explicit permission policy"
      end

      def raw_command_message(kind)
        "managed #{actor_group(kind)} may not execute raw commands"
      end

      def external_skill_message(kind)
        "managed #{actor_group(kind)} may not reference mutable external skills"
      end

      def actor_group(kind)
        return "workflow stages" if kind == :stage

        "council #{kind == :reviewer ? 'reviewers' : 'revise agents'}"
      end

      def validate_actor_mapping(actor, label, diagnostics, required_role: nil)
        if actor.agent || actor.model || actor.effort
          diagnostics << diagnostic("mapping.embedded_identity", "workflow.yml",
                                    "#{label} must not embed agent, model, or effort")
        end
        unless actor.mapping_role && actor.mapping_contract
          diagnostics << diagnostic("mapping.missing_contract", "workflow.yml",
                                    "#{label} must declare mapping_role and mapping_contract")
        end
        if required_role && actor.mapping_role != required_role
          diagnostics << diagnostic("mapping.invalid_role", "workflow.yml",
                                    "#{label} mapping_role must be #{required_role}")
        end
      end

      def validate_permission_disclosure(manifest, workflow, diagnostics)
        expected = PermissionProjection.derive!(manifest_descriptor_hash)
        unless manifest.permissions == expected
          diagnostics << diagnostic(
            "policy.disclosure_mismatch", RegistryManifest::FILE_NAME,
            "manifest permission disclosure must exactly match the conservative actor-policy projection"
          )
          return
        end
        reasons = RuntimePolicy.workflow_escalation_reasons(workflow)
        return if reasons.empty?

        permissions = manifest.permissions
        missing = []
        missing << "risk=high" unless permissions["risk"] == "high"
        if (reasons & %w[actor_yolo actor_unbounded_shell]).any?
          missing.concat(RegistryManifest::CAPABILITIES - permissions.fetch("capabilities"))
          %w[network_hosts filesystem_read filesystem_write secrets].each do |key|
            missing << "#{key}=*" unless permissions.fetch(key).include?("*")
          end
        elsif reasons.include?("actor_unbounded_write")
          missing << "filesystem-write" unless permissions.fetch("capabilities").include?("filesystem-write")
          missing << "filesystem_write=*" unless permissions.fetch("filesystem_write").include?("*")
        end
        return if missing.empty?

        diagnostics << diagnostic(
          "policy.disclosure_mismatch", RegistryManifest::FILE_NAME,
          "manifest permission disclosure is not a conservative superset of actor policy (missing: #{missing.uniq.sort.join(', ')})"
        )
      end

      def validate_hive_extension(manifest, workflow, diagnostics)
        extension = manifest.data.fetch(
          "x-hive", { "tools" => [], "optional_inputs" => [], "external_skills" => [] }
        )
        required_keys = %w[optional_inputs tools]
        optional_keys = %w[external_skills mapping_recommendations prompt_assets]
        unless extension.is_a?(Hash) && (required_keys - extension.keys).empty? &&
               (extension.keys - required_keys - optional_keys).empty?
          diagnostics << diagnostic("x-hive.invalid_shape", RegistryManifest::FILE_NAME,
                                    "x-hive must contain optional_inputs and tools plus only supported optional fields")
          return
        end
        slots = Configuration.slots_for(workflow).map(&:id)
        validate_hive_tools(extension["tools"], manifest, diagnostics)
        validate_hive_prompt_assets(extension.fetch("prompt_assets", []), manifest, diagnostics)
        validate_hive_inputs(extension["optional_inputs"], slots, diagnostics)
        validate_hive_mapping_recommendations(
          extension.fetch("mapping_recommendations", []), slots, diagnostics
        )
        validate_external_skills(extension.fetch("external_skills", []), workflow, diagnostics)
      end

      def validate_external_skills(values, workflow, diagnostics)
        valid = values.is_a?(Array) && values.all? do |value|
          value.is_a?(String) && value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._:\/-]{0,127}\z/)
        end
        unless valid && values == values.sort.uniq
          diagnostics << diagnostic(
            "x-hive.invalid_external_skills", RegistryManifest::FILE_NAME,
            "x-hive external_skills must be a sorted unique dependency-name set"
          )
          return
        end
        expected = workflow.executable_slots.filter_map { |slot| slot.actor.skill }.sort.uniq
        return if values == expected

        diagnostics << diagnostic(
          "x-hive.external_skill_mismatch", RegistryManifest::FILE_NAME,
          "x-hive external_skills must exactly match descriptor skill dependencies"
        )
      end

      def validate_hive_tools(tools, manifest, diagnostics)
        unless tools.is_a?(Array) && tools.all? { |entry| entry.is_a?(Hash) && entry.keys == [ "path" ] }
          diagnostics << diagnostic("x-hive.invalid_tools", RegistryManifest::FILE_NAME,
                                    "x-hive tools must be path-only maps")
          return
        end
        paths = tools.map { |entry| entry["path"] }
        unless paths == paths.compact.sort.uniq
          diagnostics << diagnostic("x-hive.invalid_tools", RegistryManifest::FILE_NAME,
                                    "x-hive tool paths must be a sorted unique set")
          return
        end
        inventory = manifest.file_entries.to_set { |entry| entry.fetch("path") }
        paths.each do |path|
          begin
            RegistryManifest.validate_relative_path!(path)
          rescue PackageError
            diagnostics << diagnostic("x-hive.invalid_tool_path", path.to_s,
                                      "declared tool path must remain inside the package")
            next
          end
          target = File.join(@root, path)
          unless inventory.include?(path) && File.file?(target) && !File.symlink?(target) && File.executable?(target)
            diagnostics << diagnostic("x-hive.tool_not_executable", path,
                                      "declared tool must be manifest-hashed and executable (100755)")
          end
        end
      end

      def validate_hive_inputs(inputs, slots, diagnostics)
        valid_shape = inputs.is_a?(Array) && inputs.all? do |entry|
          entry.is_a?(Hash) && entry.keys.sort == %w[authorized_slots name] &&
            entry["name"].is_a?(String) && InputName.valid?(entry["name"]) &&
            entry["authorized_slots"].is_a?(Array)
        end
        unless valid_shape
          diagnostics << diagnostic("x-hive.invalid_inputs", RegistryManifest::FILE_NAME,
                                    "x-hive optional_inputs entries are malformed")
          return
        end
        names = inputs.map { |entry| entry.fetch("name") }
        unless names == names.sort.uniq
          diagnostics << diagnostic("x-hive.invalid_inputs", RegistryManifest::FILE_NAME,
                                    "x-hive optional input names must be sorted and unique")
        end
        inputs.each do |entry|
          authorized = entry.fetch("authorized_slots")
          unless authorized == authorized.sort.uniq && !authorized.empty? && (authorized - slots).empty?
            diagnostics << diagnostic("x-hive.invalid_input_slots", RegistryManifest::FILE_NAME,
                                      "optional input #{entry.fetch('name')} must authorize known sorted stable slots")
          end
        end
      end

      def validate_hive_mapping_recommendations(recommendations, slots, diagnostics)
        valid_shape = recommendations.is_a?(Array) && recommendations.all? do |entry|
          keys = entry.is_a?(Hash) && entry.keys.sort
          keys && [ %w[slot], %w[effort slot] ].include?(keys) &&
            entry["slot"].is_a?(String) &&
            (!entry.key?("effort") || Configuration::MAPPING_RECOMMENDATION_EFFORTS.include?(entry["effort"]))
        end
        unless valid_shape
          diagnostics << diagnostic(
            "x-hive.invalid_mapping_recommendations", RegistryManifest::FILE_NAME,
            "x-hive mapping recommendations must contain only slot and an optional portable effort"
          )
          return
        end

        recommended_slots = recommendations.map { |entry| entry.fetch("slot") }
        unless recommended_slots == recommended_slots.sort.uniq
          diagnostics << diagnostic(
            "x-hive.invalid_mapping_recommendation_order", RegistryManifest::FILE_NAME,
            "x-hive mapping recommendation slots must be sorted and unique"
          )
        end
        unless (recommended_slots - slots).empty?
          diagnostics << diagnostic(
            "x-hive.invalid_mapping_recommendation_slots", RegistryManifest::FILE_NAME,
            "x-hive mapping recommendations must name known executable slots"
          )
        end
      end

      def validate_hive_prompt_assets(assets, manifest, diagnostics)
        unless assets.is_a?(Array) && assets.all? { |entry| entry.is_a?(Hash) && entry.keys == [ "path" ] }
          diagnostics << diagnostic("x-hive.invalid_prompt_assets", RegistryManifest::FILE_NAME,
                                    "x-hive prompt_assets must be path-only maps")
          return
        end
        paths = assets.map { |entry| entry["path"] }
        unless paths == paths.compact.sort.uniq
          diagnostics << diagnostic("x-hive.invalid_prompt_assets", RegistryManifest::FILE_NAME,
                                    "x-hive prompt asset paths must be a sorted unique set")
          return
        end
        inventory = manifest.file_entries.to_set { |entry| entry.fetch("path") }
        paths.each do |path|
          begin
            RegistryManifest.validate_relative_path!(path)
          rescue PackageError
            diagnostics << diagnostic("x-hive.invalid_prompt_asset_path", path.to_s,
                                      "declared prompt asset path must remain inside the package")
            next
          end
          target = File.join(@root, path)
          unless inventory.include?(path) && File.file?(target) && !File.symlink?(target)
            diagnostics << diagnostic("x-hive.prompt_asset_untrusted", path,
                                      "declared prompt asset must be manifest-hashed and regular")
          end
        end
      end

      def diagnostic(rule, path, message)
        Diagnostic.new(rule_id: rule, severity: :error, path: path, message: message)
      end

      def safe_descriptor_message(_error)
        "package workflow descriptor is invalid"
      end

      def secure_equal?(left, right)
        return false unless left.bytesize == right.bytesize

        left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
      end

      def manifest_descriptor_hash
        bytes = File.binread(File.join(@root, "workflow.yml"))
        YAML.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
      rescue Psych::Exception, SystemCallError, IOError
        raise Hive::ConfigError, "package workflow descriptor is unavailable for permission projection"
      end
    end
  end
end
