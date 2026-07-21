require "test_helper"
require "hive/draft_pr_receipt"

class DraftPrReceiptTest < Minitest::Test
  include HiveTestHelper

  def test_initializes_atomic_versioned_secret_free_receipt_and_resumes_exact_match
    with_tmp_dir do |root|
      task = File.join(root, "task")
      worktree_root = File.join(root, "worktrees")
      worktree = File.join(worktree_root, "fix-ui")
      FileUtils.mkdir_p(task)
      expected = attributes(worktree)

      first = Hive::DraftPrReceipt.initialize!(
        task, expected:, worktree_root: worktree_root
      )
      second = Hive::DraftPrReceipt.initialize!(
        task, expected:, worktree_root: worktree_root
      )

      assert_equal first, second
      assert_equal 1, first.fetch("version")
      assert_equal "worktree_created", first.fetch("phase")
      assert_equal "github.com/acme/widgets", first.fetch("repository")
      receipt_path = File.join(task, "handoff.yml")
      refute_includes File.read(receipt_path), "token"
      assert_equal 0o600, File.stat(receipt_path).mode & 0o777
      refute Dir.children(task).any? { |name| name.include?(".handoff.yml.tmp") }
    end
  end

  def test_rejects_duplicate_keys_and_symlink_without_rewriting
    with_tmp_dir do |root|
      task = File.join(root, "task")
      FileUtils.mkdir_p(task)
      path = File.join(task, "handoff.yml")
      duplicate = attributes(File.join(root, "worktrees", "fix-ui")).to_yaml + "phase: tampered\n"
      File.write(path, duplicate)

      assert_raises(Hive::WorktreeError) { Hive::DraftPrReceipt.read(task, worktree_root: root) }
      assert_equal duplicate, File.read(path)

      File.write(path, "phase: [unterminated\n")
      assert_raises(Hive::WorktreeError) { Hive::DraftPrReceipt.read(task, worktree_root: root) }

      FileUtils.rm_f(path)
      target = File.join(root, "outside.yml")
      File.write(target, attributes(File.join(root, "worktrees", "fix-ui")).to_yaml)
      File.symlink(target, path)
      assert_raises(Hive::WorktreeError) { Hive::DraftPrReceipt.read(task, worktree_root: root) }

      FileUtils.rm_f(path)
      File.binwrite(path, "x" * (Hive::DraftPrReceipt::MAX_BYTES + 1))
      error = assert_raises(Hive::WorktreeError) do
        Hive::DraftPrReceipt.read(task, worktree_root: root)
      end
      assert_includes error.message, "exceeds"
    end
  end

  def test_rejects_out_of_root_and_contradictory_expected_state
    with_tmp_dir do |root|
      task = File.join(root, "task")
      worktree_root = File.join(root, "worktrees")
      FileUtils.mkdir_p(task)
      bad = attributes(File.join(root, "outside", "fix-ui"))
      File.write(File.join(task, "handoff.yml"), bad.to_yaml)

      assert_raises(Hive::WorktreeError) do
        Hive::DraftPrReceipt.read(task, worktree_root: worktree_root)
      end

      File.write(File.join(task, "handoff.yml"), attributes(File.join(worktree_root, "fix-ui")).to_yaml)
      contradictory = attributes(File.join(worktree_root, "fix-ui")).merge("base_oid" => "b" * 40)
      assert_raises(Hive::WorktreeError) do
        Hive::DraftPrReceipt.read(task, expected: contradictory, worktree_root: worktree_root)
      end
    end
  end

  def test_phase_machine_is_atomic_monotonic_and_immutable
    with_tmp_dir do |root|
      task = File.join(root, "task")
      worktree_root = File.join(root, "worktrees")
      FileUtils.mkdir_p(task)
      Hive::DraftPrReceipt.initialize!(
        task, expected: attributes(File.join(worktree_root, "fix-ui")),
        worktree_root: worktree_root
      )
      receipt = Hive::DraftPrReceipt.advance!(
        task, from: "worktree_created", to: "agent_validated",
        attributes: { "head_oid" => "b" * 40, "report_sha256" => "c" * 64 },
        worktree_root: worktree_root
      )
      assert_equal "agent_validated", receipt.fetch("phase")
      assert_raises(Hive::WorktreeError) do
        Hive::DraftPrReceipt.advance!(
          task, from: "agent_validated", to: "pr_observed", attributes: {},
          worktree_root: worktree_root
        )
      end
      assert_raises(Hive::WorktreeError) do
        Hive::DraftPrReceipt.update!(
          task, phase: "agent_validated", attributes: { "head_oid" => "d" * 40 },
          worktree_root: worktree_root
        )
      end
      assert_equal "b" * 40,
                   Hive::DraftPrReceipt.read(task, worktree_root: worktree_root).fetch("head_oid")
      premature = Hive::DraftPrReceipt.read(task, worktree_root: worktree_root)
                                           .merge("pr_url" => "https://github.com/acme/widgets/pull/7")
      File.write(File.join(task, "handoff.yml"), premature.to_yaml)
      assert_raises(Hive::WorktreeError) do
        Hive::DraftPrReceipt.read(task, worktree_root: worktree_root)
      end
      refute Dir.children(task).any? { |name| name.include?("handoff.yml.tmp") }
    end
  end

  def test_rejects_pr_url_that_contradicts_recorded_repository_or_number
    with_tmp_dir do |root|
      data = attributes(File.join(root, "worktrees", "fix-ui")).merge(
        "phase" => "terminal",
        "head_oid" => "b" * 40,
        "report_sha256" => "c" * 64,
        "terminal_outcome" => "blocked",
        "terminal_at" => "2026-07-21T12:00:00Z",
        "error_reason" => "draft_pr_identity_blocked",
        "pr_number" => 7,
        "pr_url" => "https://github.com/other/repository/pull/8"
      )
      task = File.join(root, "task")
      FileUtils.mkdir_p(task)
      File.write(File.join(task, "handoff.yml"), data.to_yaml)

      error = assert_raises(Hive::WorktreeError) do
        Hive::DraftPrReceipt.read(task, worktree_root: File.join(root, "worktrees"))
      end
      assert_includes error.message, "contradicts"
    end
  end

  private

  def attributes(worktree)
    {
      "version" => 1,
      "phase" => "worktree_created",
      "repository" => "github.com/acme/widgets",
      "base_branch" => "main",
      "base_oid" => "a" * 40,
      "task_branch" => "fix-ui",
      "worktree_path" => worktree
    }
  end
end
