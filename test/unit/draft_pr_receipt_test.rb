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
