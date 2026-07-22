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
end
