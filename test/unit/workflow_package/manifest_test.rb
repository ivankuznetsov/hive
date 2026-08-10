require "test_helper"
require "json"
require "hive/workflow_package/manifest"

class WorkflowPackageManifestTest < Minitest::Test
  include HiveTestHelper

  def test_build_is_canonical_and_hashes_every_payload_file_once
    with_package do |root|
      first = Hive::WorkflowPackage::Manifest.build(root, metadata: metadata)
      second = Hive::WorkflowPackage::Manifest.build(root, metadata: metadata.transform_keys(&:to_sym))

      assert_equal first.bytes, second.bytes
      assert first.bytes.end_with?("\n")
      refute first.bytes.end_with?("\n\n")

      paths = first.data.fetch("files").map { |entry| entry.fetch("path") }
      assert_equal %w[README.md honeycomb.yml instructions/work.md workflow.yml], paths
      refute_includes paths, "manifest.json"
      assert_equal paths.uniq, paths
      assert_match(/\A[0-9a-f]{64}\z/, first.digest)
    end
  end

  def test_rejects_links_and_case_colliding_paths
    with_package do |root|
      File.symlink("README.md", File.join(root, "linked.md"))
      error = assert_raises(Hive::WorkflowPackage::PackageError) do
        Hive::WorkflowPackage::Manifest.build(root, metadata: metadata)
      end
      assert_equal "package.symlink", error.diagnostic.rule_id

      File.delete(File.join(root, "linked.md"))
      File.write(File.join(root, "readme.MD"), "collision\n")
      error = assert_raises(Hive::WorkflowPackage::PackageError) do
        Hive::WorkflowPackage::Manifest.build(root, metadata: metadata)
      end
      assert_equal "package.path_case_collision", error.diagnostic.rule_id
    end
  end

  def test_load_rejects_noncanonical_invalid_and_missing_manifests
    with_package do |root|
      manifest = Hive::WorkflowPackage::Manifest.build(root, metadata: metadata)
      path = File.join(root, "manifest.json")
      File.write(path, JSON.pretty_generate(manifest.data))
      assert_rule("manifest.non_canonical") { Hive::WorkflowPackage::Manifest.load(path) }

      File.write(path, "{not-json")
      assert_rule("manifest.invalid_json") { Hive::WorkflowPackage::Manifest.load(path) }
      FileUtils.rm_f(path)
      assert_rule("manifest.unreadable") { Hive::WorkflowPackage::Manifest.load(path) }
    end
  end

  def test_shape_helpers_reject_invalid_names_paths_values_and_duplicates
    assert_rule("manifest.invalid_name") { Hive::WorkflowPackage::Manifest.validate_name!("Bad Name") }
    assert_rule("package.invalid_path") { Hive::WorkflowPackage::Manifest.validate_relative_path!(nil) }
    assert_rule("package.path_escape") { Hive::WorkflowPackage::Manifest.validate_relative_path!("../outside") }
    assert_rule("manifest.invalid_value") { Hive::WorkflowPackage::Manifest.required_string!("", "summary") }
    assert_rule("manifest.invalid_value") { Hive::WorkflowPackage::Manifest.string_array!([ "" ], "tools") }
    assert_rule("manifest.duplicate_value") do
      Hive::WorkflowPackage::Manifest.string_array!(%w[Read Read], "tools")
    end
  end

  def test_inventory_rejects_special_files_and_unreadable_roots
    with_package do |root|
      fifo = File.join(root, "pipe")
      File.mkfifo(fifo)
      assert_rule("package.special_file") { Hive::WorkflowPackage::Manifest.inventory(root) }
    end
    assert_rule("package.unreadable") do
      Hive::WorkflowPackage::Manifest.inventory(File.join(Dir.tmpdir, "missing-hive-package-#{Process.pid}"))
    end
  end

  def test_inventory_rejects_invalid_utf8_when_text_is_required
    with_tmp_dir do |root|
      File.binwrite(File.join(root, "bad.txt"), "\xFF".b)

      assert_rule("package.invalid_encoding") do
        Hive::WorkflowPackage::Manifest.inventory(root)
      end
      assert_equal 1, Hive::WorkflowPackage::Manifest.inventory(root, require_utf8: false).length
    end
  end

  private

  def assert_rule(rule)
    error = assert_raises(Hive::WorkflowPackage::PackageError) { yield }
    assert_equal rule, error.diagnostic.rule_id
    error
  end

  def metadata
    {
      "name" => "demo",
      "version" => "1.0.0",
      "summary" => "A deterministic demo",
      "author" => { "name" => "Test Author" },
      "dependencies" => { "hive" => ">= 0.4.2", "executables" => [] },
      "permissions" => { "tools" => [ "Read" ], "deny" => [ "Bash" ], "directories" => [],
                           "commands" => [], "domains" => [], "credentials" => [] }
    }
  end

  def with_package
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, "instructions"))
      File.write(File.join(root, "README.md"), "# Demo\n")
      File.write(File.join(root, "honeycomb.yml"), "name: demo\nversion: 1.0.0\n")
      File.write(File.join(root, "instructions", "work.md"), "Read the repository.\n")
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
