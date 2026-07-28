require "digest"
require "test_helper"
require "hive/module_package/validator"
require "hive/workflow_package/canonical_yaml"

class ModulePackageValidatorTest < Minitest::Test
  include HiveTestHelper

  def test_validates_complete_inventory_and_trusted_identity
    with_package do |root, document|
      result = Hive::ModulePackage::Validator.validate(
        root,
        expected_name: "demo",
        expected_manifest_digest: document.fetch("release_sha256")
      )

      assert result.valid?, result.diagnostics.map(&:to_s).join("\n")
      assert_equal "demo", result.descriptor.name
    end
  end

  def test_reports_unlisted_missing_hash_and_catalog_metadata_drift
    with_package do |root, document|
      File.write(File.join(root, "README.md"), "tampered\n")
      File.write(File.join(root, "extra.txt"), "extra\n")

      result = Hive::ModulePackage::Validator.validate(
        root, expected_name: "other", expected_manifest_digest: "0" * 64
      )

      rules = result.errors.map(&:rule_id)
      assert_includes rules, "manifest.name_mismatch"
      assert_includes rules, "manifest.digest_mismatch"
      assert_includes rules, "manifest.hash_mismatch"
      assert_includes rules, "manifest.unlisted_file"
    end
  end

  def test_reports_version_manifest_inventory_and_mode_failures
    with_package do |root, document|
      document["hive_min_version"] = "999.0.0"
      rewrite_manifest(root, document)
      result = Hive::ModulePackage::Validator.validate(root)
      assert_includes result.errors.map(&:rule_id), "manifest.hive_version_unsupported"
    end

    with_package do |root, _document|
      FileUtils.rm_f(File.join(root, "README.md"))
      result = Hive::ModulePackage::Validator.validate(root)
      assert_includes result.errors.map(&:rule_id), "manifest.missing_file"
    end

    with_package do |root, _document|
      File.chmod(0o755, File.join(root, "README.md"))
      result = Hive::ModulePackage::Validator.validate(root)
      assert_includes result.errors.map(&:rule_id), "package.executable_file"
    end

    with_package do |root, _document|
      FileUtils.cp(File.join(root, "module.yml"), File.join(root, "manifest.yml"))
      result = Hive::ModulePackage::Validator.validate(root)
      refute result.valid?
      assert_equal "manifest.ambiguous", result.errors.first.rule_id
    end

    with_tmp_dir do |root|
      File.write(File.join(root, "module.yml"), "{bad")
      result = Hive::ModulePackage::Validator.validate(root)
      refute result.valid?
      assert_equal "manifest.invalid_yaml", result.errors.first.rule_id
    end
  end

  def test_parses_every_declared_workflow_and_bounds_descriptor_errors
    with_package do |root, document|
      path = File.join(root, "review.yml")
      File.write(path, <<~YAML)
        id: review
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
      YAML
      document["workflows"] = [ { "id" => "review", "descriptor" => "review.yml" } ]
      document["hooks"] = [
        {
          "id" => "review", "target" => { "kind" => "workflow", "id" => "review" },
          "default_enabled" => true, "schedules" => [],
          "events" => [ "task.completed" ], "concurrency" => "drop"
        }
      ]
      document["files"]["review.yml"] = Digest::SHA256.file(path).hexdigest
      document["files"] = document["files"].sort.to_h
      rewrite_manifest(root, document)

      assert Hive::ModulePackage::Validator.validate(root).valid?

      File.write(path, "id: leaked-name\nstages: []\n")
      document["files"]["review.yml"] = Digest::SHA256.file(path).hexdigest
      rewrite_manifest(root, document)
      result = Hive::ModulePackage::Validator.validate(root)

      refute result.valid?
      diagnostic = result.errors.find { |row| row.rule_id == "workflow.invalid" }
      refute_nil diagnostic
      assert_equal "review.yml", diagnostic.path
      assert_equal "module workflow descriptor is invalid", diagnostic.message
      refute_includes diagnostic.message, "leaked-name"
    end
  end

  private

  def with_package
    with_tmp_dir do |root|
      File.write(File.join(root, "README.md"), "# Demo\n")
      document = {
        "schema" => "hive-module/v1", "name" => "demo", "version" => "1.0.0",
        "description" => "Demo module", "type" => "workflow",
        "author" => { "name" => "Hive", "url" => "https://hivecli.sh" }, "license" => "MIT",
        "hive_min_version" => "0.6.7",
        "source" => { "url" => "https://example.test/demo", "revision" => "a" * 40 },
        "workflows" => [], "hooks" => [], "settings" => [],
        "permissions" => {
          "repository_write" => false, "github_mutations" => [], "external_commands" => [],
          "network_hosts" => [], "filesystem_read" => [], "filesystem_write" => [], "secrets" => []
        },
        "templates" => [], "docs" => [ "README.md" ],
        "files" => { "README.md" => Digest::SHA256.file(File.join(root, "README.md")).hexdigest }
      }
      document["release_sha256"] = Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalYAML.dump(document))
      File.binwrite(File.join(root, "module.yml"), Hive::WorkflowPackage::CanonicalYAML.dump(document))
      yield root, document
    end
  end

  def rewrite_manifest(root, document)
    unsigned = document.reject { |key, _value| key == "release_sha256" }
    document["release_sha256"] = Digest::SHA256.hexdigest(
      Hive::WorkflowPackage::CanonicalYAML.dump(unsigned)
    )
    File.binwrite(File.join(root, "module.yml"), Hive::WorkflowPackage::CanonicalYAML.dump(document))
  end
end
