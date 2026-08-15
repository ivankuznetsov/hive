require "test_helper"
require "hive/task_workspace/artifacts"

class TaskWorkspaceArtifactsTest < Minitest::Test
  include HiveTestHelper

  def test_preserves_order_redacts_and_reports_per_file_truncation
    with_tmp_dir do |root|
      File.binwrite(File.join(root, "idea.md"), "token=ghp_abcdefghijklmnopqrstuvwxyz1234567890\n")
      File.binwrite(File.join(root, "plan.md"), "p" * 20)
      service = Hive::TaskWorkspace::Artifacts.new(
        task_root: root, references: %w[idea.md missing.md plan.md],
        limits: Hive::TaskWorkspace::Limits.new(artifact_bytes: 12)
      )

      panel = service.call

      assert_equal %w[idea.md plan.md], panel.fetch("records").map { |row| row.fetch("name") }
      refute_includes panel.fetch("records").first.fetch("content"), "ghp_"
      assert panel.fetch("records").all? { |row| row.fetch("truncated") }
      assert_equal "partial", panel.fetch("state")
    end
  end

  def test_binary_invalid_utf8_symlink_and_aggregate_exhaustion_are_panel_local
    with_tmp_dir do |root|
      File.binwrite(File.join(root, "binary.dat"), "a\0b")
      File.binwrite(File.join(root, "invalid.md"), "bad\xff".b)
      File.binwrite(File.join(root, "large.md"), "x" * 32)
      File.binwrite(File.join(root, "after.md"), "after")
      File.symlink(File.join(root, "large.md"), File.join(root, "linked.md"))
      panel = Hive::TaskWorkspace::Artifacts.new(
        task_root: root,
        references: %w[binary.dat invalid.md linked.md large.md after.md],
        limits: Hive::TaskWorkspace::Limits.new(
          artifact_bytes: 16, artifact_total_bytes: 20
        )
      ).call

      binary = panel.fetch("records").find { |row| row["name"] == "binary.dat" }
      assert binary.fetch("binary")
      assert_nil binary.fetch("content")
      assert panel.fetch("records").find { |row| row["name"] == "invalid.md" }
        .fetch("invalid_encoding")
      reasons = panel.fetch("diagnostics").map { |row| row.fetch("reason") }
      assert_includes reasons, "symlink_refused"
      assert_includes reasons, "aggregate_budget_exhausted"
      assert_equal "partial", panel.fetch("state")
    end
  end

  def test_file_count_and_hostile_references_are_bounded
    with_tmp_dir do |root|
      3.times { |index| File.write(File.join(root, "#{index}.md"), index.to_s) }
      panel = Hive::TaskWorkspace::Artifacts.new(
        task_root: root,
        references: [ "../secret", "/etc/passwd", "0.md", "1.md", "2.md" ],
        limits: Hive::TaskWorkspace::Limits.new(artifact_files: 2)
      ).call

      assert_equal 2, panel.fetch("records").length
      assert_equal %w[0.md 1.md], panel.fetch("records").map { |row| row.fetch("name") }
      assert_includes panel.fetch("diagnostics").map { |row| row["reason"] }, "invalid_reference"
      assert_includes panel.fetch("diagnostics").filter_map { |row| row["cap"] }, "artifact_files"
      refute_includes panel.to_s, "/etc/passwd"
    end
  end

  def test_changing_descriptor_degrades_without_raising
    with_tmp_dir do |root|
      File.write(File.join(root, "idea.md"), "before")
      reader = Object.new
      reader.define_singleton_method(:read) do |*|
        raise Hive::TaskWorkspace::SourceError.new(
          source: "artifact", reason: "source_changed"
        )
      end

      panel = Hive::TaskWorkspace::Artifacts.new(
        task_root: root, references: [ "idea.md" ], reader: reader
      ).call

      assert_equal "partial", panel.fetch("state")
      assert_empty panel.fetch("records")
      assert_equal "source_changed", panel.dig("diagnostics", 0, "reason")
    end
  end
end
