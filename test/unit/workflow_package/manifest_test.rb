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

  private

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
