require "digest"
require "test_helper"
require "hive/agent_profiles"
require "hive/workflow_package/canonical_yaml"
require "hive/workflow_package/registry_manifest"
require "hive/workflow_package/runtime_policy"
require "hive/workflow_package/validator"

class WorkflowPackageRegistryManifestTest < Minitest::Test
  include HiveTestHelper

  def test_validator_accepts_canonical_registry_manifest_and_release_digest
    with_registry_package do |root, document|
      result = Hive::WorkflowPackage::Validator.validate(
        root, expected_name: "demo", expected_manifest_digest: document.fetch("release_sha256")
      )

      assert result.valid?, result.diagnostics.map(&:to_s).join("\n")
      assert_instance_of Hive::WorkflowPackage::RegistryManifest, result.manifest
      assert_equal document.fetch("release_sha256"), result.manifest_digest
      assert_equal %w[README.md instructions/work.md workflow.yml], result.manifest.file_entries.map { |entry| entry.fetch("path") }
    end
  end

  def test_validator_rejects_payload_tamper_and_both_manifest_formats
    with_registry_package do |root, _document|
      File.write(File.join(root, "README.md"), "tampered\n")
      result = Hive::WorkflowPackage::Validator.validate(root)
      assert_includes result.errors.map(&:rule_id), "manifest.hash_mismatch"

      File.write(File.join(root, "manifest.json"), "{}\n")
      result = Hive::WorkflowPackage::Validator.validate(root)
      assert_equal "manifest.ambiguous", result.errors.first.rule_id
    end
  end

  def test_registry_manifest_rejects_noncanonical_yaml_and_release_fingerprint_drift
    with_registry_package do |root, document|
      path = File.join(root, "manifest.yml")
      File.binwrite(path, Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document).sub("schema:", "schema: "))
      error = assert_raises(Hive::WorkflowPackage::PackageError) do
        Hive::WorkflowPackage::RegistryManifest.load(path)
      end
      assert_equal "manifest.non_canonical", error.diagnostic.rule_id

      document["description"] = "Changed without regenerating release identity"
      File.binwrite(path, Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document))
      error = assert_raises(Hive::WorkflowPackage::PackageError) do
        Hive::WorkflowPackage::RegistryManifest.load(path)
      end
      assert_equal "manifest.release_digest_mismatch", error.diagnostic.rule_id
    end
  end

  def test_v2_disclosure_is_not_silently_treated_as_legacy_runtime_policy
    with_registry_package do |root, document|
      with_tmp_dir do |policy_root|
        task = File.join(policy_root, "task")
        FileUtils.mkdir_p(task)
        error = assert_raises(Hive::ConfigError) do
          Hive::WorkflowPackage::RuntimePolicy.compile(
            document.fetch("permissions"), task_folder: task,
            profile: Hive::AgentProfiles.lookup(:claude), policy_dir: File.join(policy_root, "policy")
          )
        end
        assert_match(/cannot be safely admitted/, error.message)
      end
    end
  end

  def test_validator_rejects_a_manifest_requiring_a_future_hive
    with_registry_package do |root, document|
      document["hive_min_version"] = "99.0.0"
      document["release_sha256"] = Digest::SHA256.hexdigest(
        Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document, include_release: false)
      )
      File.binwrite(File.join(root, "manifest.yml"), Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document))

      result = Hive::WorkflowPackage::Validator.validate(root)
      diagnostic = result.errors.find { |item| item.rule_id == "manifest.hive_version_unsupported" }
      assert diagnostic
      assert_includes diagnostic.message, Hive::VERSION
      assert_includes diagnostic.message, "99.0.0"
    end
  end

  def test_validator_ignores_semver_build_metadata_when_comparing_hive_versions
    with_registry_package do |root, document|
      document["hive_min_version"] = "#{Hive::VERSION}+registry.1"
      document["release_sha256"] = Digest::SHA256.hexdigest(
        Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document, include_release: false)
      )
      File.binwrite(File.join(root, "manifest.yml"), Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document))

      result = Hive::WorkflowPackage::Validator.validate(root)
      assert result.valid?, result.diagnostics.map(&:to_s).join("\n")
    end
  end

  def test_task_local_read_only_v2_disclosure_has_a_lossless_runtime_mapping
    with_registry_package do |_root, document|
      document["permissions"]["filesystem_read"] = [ "task" ]
      with_tmp_dir do |policy_root|
        task = File.join(policy_root, "task")
        FileUtils.mkdir_p(task)
        policy = Hive::WorkflowPackage::RuntimePolicy.compile(
          document.fetch("permissions"), task_folder: task,
          profile: Hive::AgentProfiles.lookup(:claude), policy_dir: File.join(policy_root, "policy")
        )
        assert_equal %w[Glob Grep LS Read], policy.allowed_tools
        assert_includes policy.disallowed_tools, "Bash"
        assert_equal [ task ], policy.directories
      end
    end
  end

  private

  def with_registry_package
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, "instructions"))
      File.write(File.join(root, "README.md"), "# Demo\n")
      File.write(File.join(root, "instructions", "work.md"), "Read files only.\n")
      File.write(File.join(root, "workflow.yml"), <<~YAML)
        id: demo
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: work
            kind: agent
            state_file: work.md
            advance_verb: work
            instruction: instructions/work.md
            permissions: read-only
          - name: done
            kind: terminal
            state_file: done.md
            advance_verb: done
      YAML
      prefix = "packages/demo/1.0.0/"
      files = %w[README.md instructions/work.md workflow.yml].to_h do |relative|
        [ "#{prefix}#{relative}", Digest::SHA256.file(File.join(root, relative)).hexdigest ]
      end
      document = {
        "schema" => "honeycomb-manifest/v1", "name" => "demo", "version" => "1.0.0",
        "description" => "Demo", "author" => { "name" => "Test", "url" => "https://example.test/test" },
        "license" => "MIT", "hive_min_version" => "0.4.3",
        "source" => { "url" => "https://example.test/source", "revision" => "c" * 40 },
        "permissions" => {
          "risk" => "low", "capabilities" => [ "filesystem-read" ], "network_hosts" => [],
          "filesystem_read" => %w[repository task], "filesystem_write" => [], "secrets" => []
        },
        "files" => files
      }
      document["release_sha256"] = Digest::SHA256.hexdigest(
        Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document, include_release: false)
      )
      File.binwrite(File.join(root, "manifest.yml"), Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document))
      yield root, document
    end
  end
end
