require "test_helper"
require "hive/task_workspace"

class TaskWorkspaceBoundedReaderTest < Minitest::Test
  include HiveTestHelper

  def test_reads_redacts_scrubs_and_accounts_for_a_bounded_regular_file
    with_tmp_dir do |root|
      token = "ghp_#{'a' * 36}"
      File.binwrite(File.join(root, "artifact.md"), "before \xFF #{token} after")
      budget = Hive::TaskWorkspace::BoundedReader::Budget.new(128)
      result = Hive::TaskWorkspace::BoundedReader.new(root: root).read(
        "artifact.md", max_bytes: 128, budget: budget
      )

      assert_includes result.content, "?"
      assert_includes result.content, "[REDACTED:github_token]"
      refute_includes result.content, token
      assert result.invalid_encoding
      refute result.truncated
      assert_equal result.bytes, budget.consumed
      assert_equal "artifact.md", result.evidence_ref
    end
  end

  def test_enforces_per_file_and_aggregate_limits
    with_tmp_dir do |root|
      File.write(File.join(root, "one.txt"), "a" * 20)
      File.write(File.join(root, "two.txt"), "b" * 20)
      reader = Hive::TaskWorkspace::BoundedReader.new(root: root)
      budget = Hive::TaskWorkspace::BoundedReader::Budget.new(12)

      first = reader.read("one.txt", max_bytes: 8, budget: budget)
      second = reader.read("two.txt", max_bytes: 8, budget: budget)

      assert_equal 8, first.bytes
      assert first.truncated
      assert_equal 4, second.bytes
      assert second.truncated
      assert_equal 12, budget.consumed
      assert_raises(Hive::TaskWorkspace::SourceError) do
        reader.read("one.txt", max_bytes: 8, budget: budget)
      end
    end
  end

  def test_redacts_a_secret_prefix_cut_by_the_display_ceiling
    with_tmp_dir do |root|
      File.write(File.join(root, "token.txt"), "before ghp_#{'a' * 36} after")

      result = Hive::TaskWorkspace::BoundedReader.new(root: root).read(
        "token.txt", max_bytes: 15
      )

      assert result.truncated
      refute_includes result.content, "ghp_"
      assert_includes result.content, "[REDACT"
    end
  end

  def test_rejects_traversal_and_symlinks
    with_tmp_dir do |root|
      outside = File.join(File.dirname(root), "workspace-outside-#{File.basename(root)}")
      File.write(outside, "secret")
      File.symlink(outside, File.join(root, "linked.txt"))
      reader = Hive::TaskWorkspace::BoundedReader.new(root: root)

      assert_raises(Hive::TaskWorkspace::SourceError) { reader.read("../x", max_bytes: 10) }
      assert_raises(Hive::TaskWorkspace::SourceError) { reader.read("linked.txt", max_bytes: 10) }
    ensure
      FileUtils.rm_f(outside) if outside
    end
  end

  def test_panel_wrapper_degrades_only_the_failed_panel
    panel = Hive::TaskWorkspace.panel("timeline") do
      raise Hive::TaskWorkspace::SourceError.new(
        source: "task_journal", reason: "invalid_json", message: "bad token"
      )
    end

    assert_equal "unavailable", panel.fetch("state")
    assert_equal "invalid_json", panel.dig("diagnostics", 0, "reason")
    assert_equal [], panel.fetch("records")
  end
end
