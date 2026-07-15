require "test_helper"
require "json"
require "hive/workflow_package/manifest"
require "hive/workflow_package/validator"

class WorkflowPackageValidatorTest < Minitest::Test
  include HiveTestHelper

  def test_validates_manifest_inventory_digest_and_package_descriptor_name
    with_package do |root|
      manifest = write_manifest(root)
      result = Hive::WorkflowPackage::Validator.validate(
        root,
        expected_name: "demo",
        expected_manifest_digest: manifest.digest
      )

      assert result.valid?, result.diagnostics.map(&:message).join("\n")
      assert_equal :demo, result.workflow.id
      assert_equal manifest.digest, result.manifest_digest
    end
  end

  def test_detects_tampering_and_unlisted_extras
    with_package do |root|
      write_manifest(root)
      File.write(File.join(root, "README.md"), "tampered\n")
      File.write(File.join(root, "extra.txt"), "extra\n")

      result = Hive::WorkflowPackage::Validator.validate(root, expected_name: "demo")
      refute result.valid?
      assert_includes result.errors.map(&:rule_id), "manifest.hash_mismatch"
      assert_includes result.errors.map(&:rule_id), "manifest.unlisted_file"
    end
  end

  def test_rejects_secret_without_placing_secret_bytes_in_any_diagnostic_shape
    secret = "ghp_#{'A' * 40}"
    with_package(instruction: "Use #{secret} to inspect the repository.\n") do |root|
      write_manifest(root)
      result = Hive::WorkflowPackage::Validator.validate(root, expected_name: "demo")

      refute result.valid?
      assert_includes result.errors.map(&:rule_id), "security.github_token"
      rendered = JSON.generate(result.to_h) + result.diagnostics.map(&:to_s).join
      refute_includes rendered, secret
    end
  end

  def test_rejects_manifest_unknown_keys_and_reports_upgrade_hint
    with_package do |root|
      manifest = write_manifest(root)
      data = manifest.data.merge("future" => true)
      File.write(File.join(root, "manifest.json"), JSON.generate(data) + "\n")

      result = Hive::WorkflowPackage::Validator.validate(root, expected_name: "demo")
      refute result.valid?
      diagnostic = result.errors.find { |item| item.rule_id == "manifest.unknown_key" }
      assert_includes diagnostic.message, "upgrade"
    end
  end

  private

  def metadata
    {
      "name" => "demo", "version" => "1.0.0", "summary" => "Demo",
      "author" => { "name" => "Test Author" },
      "dependencies" => { "hive" => ">= 0.4.2", "executables" => [] },
      "permissions" => {
        "tools" => [ "Read" ], "deny" => [ "Bash", "WebFetch", "WebSearch" ],
        "directories" => [], "commands" => [], "domains" => [], "credentials" => []
      }
    }
  end

  def write_manifest(root)
    manifest = Hive::WorkflowPackage::Manifest.build(root, metadata: metadata)
    File.binwrite(File.join(root, "manifest.json"), manifest.bytes)
    manifest
  end

  def with_package(instruction: "Read files only.\n")
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, "instructions"))
      File.write(File.join(root, "README.md"), "# Demo\n")
      File.write(File.join(root, "honeycomb.yml"), "name: demo\nversion: 1.0.0\n")
      File.write(File.join(root, "instructions", "work.md"), instruction)
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
      yield root
    end
  end
end
