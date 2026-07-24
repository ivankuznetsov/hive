require "test_helper"
require "hive/workflow_package/source_snapshot"

class WorkflowPackageSourceSnapshotTest < Minitest::Test
  include HiveTestHelper

  Snapshot = Hive::WorkflowPackage::SourceSnapshot

  def test_snapshots_only_referenced_instructions_and_declared_assets
    with_source_tree do |workflows, authored, descriptor, metadata|
      File.write(File.join(authored, "unused.txt"), "ignored\n")

      snapshot = Snapshot.capture(
        name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
        authored_dir: authored, metadata: metadata
      )

      assert_equal %w[README.md assets/context.txt instructions/work.md workflow.yml], snapshot.files.keys
      assert_equal [ "external/reviewer" ], snapshot.external_skills
      refute_includes snapshot.files.values.map(&:bytes).join, "ignored"
      rewritten = YAML.safe_load(snapshot.files.fetch("workflow.yml").bytes)
      assert_equal "instructions/work.md", rewritten.dig("stages", 1, "instruction")
    end
  end

  def test_rejects_symlinks_traversal_and_undeclared_missing_files
    with_source_tree do |workflows, authored, descriptor, metadata|
      FileUtils.rm_f(File.join(authored, "work.md"))
      File.symlink("README.md", File.join(authored, "work.md"))
      assert_raises(Hive::ConfigError) do
        Snapshot.capture(name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
                         authored_dir: authored, metadata: metadata)
      end

      FileUtils.rm_f(File.join(authored, "work.md"))
      File.write(File.join(authored, "work.md"), "work\n")
      bad = metadata.with(assets: [ "../outside.txt" ])
      assert_raises(Hive::ConfigError) do
        Snapshot.capture(name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
                         authored_dir: authored, metadata: bad)
      end
    end
  end

  def test_rejects_symlinked_intermediate_directories
    with_source_tree do |workflows, authored, descriptor, metadata|
      outside = File.join(File.dirname(workflows), "outside")
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "context.txt"), "escaped\n")
      FileUtils.rm_rf(File.join(authored, "assets"))
      File.symlink(outside, File.join(authored, "assets"))

      error = assert_raises(Hive::ConfigError) do
        Snapshot.capture(
          name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
          authored_dir: authored, metadata: metadata
        )
      end

      assert_match(/linked|symlink|owned workflow root/, error.message)
    end
  end

  private

  def with_source_tree
    with_tmp_dir do |root|
      workflows = File.join(root, "workflows")
      authored = File.join(workflows, "demo")
      FileUtils.mkdir_p(File.join(authored, "assets"))
      descriptor = File.join(workflows, "demo.yml")
      File.write(descriptor, <<~YAML)
        id: demo
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: work
            kind: agent
            state_file: work.md
            instruction: ./demo/work.md
            skill: external/reviewer
            mapping_role: development
            mapping_contract: demo-work-v1
            permissions: read-only
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      File.write(File.join(authored, "work.md"), "work\n")
      File.write(File.join(authored, "README.md"), "# Demo\n")
      File.write(File.join(authored, "assets", "context.txt"), "context\n")
      metadata = Data.define(:assets).new(assets: [ "assets/context.txt" ])
      yield workflows, authored, descriptor, metadata
    end
  end
end
