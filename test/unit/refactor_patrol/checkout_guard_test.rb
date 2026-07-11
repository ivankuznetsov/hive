require "test_helper"
require "hive/refactor_patrol/checkout_guard"

class RefactorPatrolCheckoutGuardTest < Minitest::Test
  include HiveTestHelper

  def test_validates_clean_default_checkout_containing_merge_and_detects_head_movement
    with_tmp_git_repo do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      guard = Hive::RefactorPatrol::CheckoutGuard.new(repo, default_branch: "master")

      snapshot = guard.validate_and_snapshot!(merge_sha: head)
      assert_equal head, snapshot.fetch("analysis_sha")
      guard.assert_unchanged!(snapshot)

      File.write(File.join(repo, "README.md"), "moved\n")
      run!("git", "-C", repo, "add", "README.md")
      run!("git", "-C", repo, "commit", "-m", "move", "--quiet")
      assert_raises(Hive::GitError) { guard.assert_unchanged!(snapshot) }
    end
  end

  def test_fails_closed_for_dirty_off_branch_detached_and_missing_merge
    with_tmp_git_repo do |repo|
      guard = Hive::RefactorPatrol::CheckoutGuard.new(repo, default_branch: "master")
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip

      File.write(File.join(repo, "README.md"), "dirty\n")
      assert_raises(Hive::GitError) { guard.validate_and_snapshot!(merge_sha: head) }
      run!("git", "-C", repo, "restore", "README.md")

      run!("git", "-C", repo, "switch", "-c", "feature", "--quiet")
      assert_raises(Hive::GitError) { guard.validate_and_snapshot!(merge_sha: head) }
      run!("git", "-C", repo, "switch", "master", "--quiet")

      run!("git", "-C", repo, "checkout", "--detach", "--quiet")
      assert_raises(Hive::GitError) { guard.validate_and_snapshot!(merge_sha: head) }
      run!("git", "-C", repo, "switch", "master", "--quiet")

      assert_raises(Hive::GitError) { guard.validate_and_snapshot!(merge_sha: "f" * 40) }
    end
  end

  def test_fails_closed_when_merge_commit_exists_but_is_not_on_registered_trunk
    with_tmp_git_repo do |repo|
      base = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      run!("git", "-C", repo, "switch", "-c", "unmerged", "--quiet")
      File.write(File.join(repo, "side.txt"), "side\n")
      run!("git", "-C", repo, "add", "side.txt")
      run!("git", "-C", repo, "commit", "-m", "side", "--quiet")
      merge_sha = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      run!("git", "-C", repo, "switch", "master", "--quiet")
      assert_equal base, run!("git", "-C", repo, "rev-parse", "HEAD").strip

      error = assert_raises(Hive::GitError) do
        Hive::RefactorPatrol::CheckoutGuard.new(repo, default_branch: "master")
                                          .validate_and_snapshot!(merge_sha: merge_sha)
      end

      assert_includes error.message, "does not contain merge commit"
    end
  end
end
