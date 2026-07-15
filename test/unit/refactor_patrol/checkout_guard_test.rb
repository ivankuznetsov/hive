require "test_helper"
require "hive/refactor_patrol/checkout_guard"

class HiveRefactorPatrolCheckoutGuardTest < Minitest::Test
  include HiveTestHelper

  def test_healthy_checkout_returns_pinned_snapshot_and_detects_later_movement
    with_tmp_git_repo do |repo|
      snapshot = guard(repo).acquire!
      assert_equal File.realpath(repo), snapshot.root_realpath
      assert_equal "master", snapshot.branch
      assert_equal run!("git", "-C", repo, "rev-parse", "HEAD").strip, snapshot.head_sha
      assert guard(repo).assert_unchanged!(snapshot)

      File.write(File.join(repo, "README.md"), "moved\n")
      error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) do
        guard(repo).assert_unchanged!(snapshot)
      end
      assert_equal "checkout_dirty", error.reason
    ensure
      snapshot&.release
    end
  end

  def test_missing_detached_wrong_branch_dirty_stale_operation_and_busy_are_distinct
    with_tmp_dir do |missing|
      error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) { guard(File.join(missing, "none")).acquire! }
      assert_equal "checkout_missing", error.reason
    end

    with_tmp_git_repo do |repo|
      run!("git", "-C", repo, "checkout", "--detach", "--quiet")
      error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) { guard(repo).acquire! }
      assert_equal "checkout_detached", error.reason
    end

    with_tmp_git_repo do |repo|
      run!("git", "-C", repo, "checkout", "-b", "feature", "--quiet")
      error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) { guard(repo).acquire! }
      assert_equal "checkout_wrong_branch", error.reason
    end

    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "dirty.txt"), "dirty\n")
      error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) { guard(repo).acquire! }
      assert_equal "checkout_dirty", error.reason
    end

    with_tmp_git_repo do |repo|
      git_dir = run!("git", "-C", repo, "rev-parse", "--absolute-git-dir").strip
      File.write(File.join(git_dir, "MERGE_HEAD"), "0" * 40)
      error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) { guard(repo).acquire! }
      assert_equal "checkout_operation_in_progress", error.reason
    end

    with_tmp_git_repo do |repo|
      run!("git", "-C", repo, "remote", "add", "origin", repo)
      error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) { guard(repo).acquire! }
      assert_equal "checkout_stale", error.reason
    end

    with_tmp_git_repo do |repo|
      first = guard(repo).acquire!
      error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) { guard(repo).acquire! }
      assert_equal "checkout_busy", error.reason
    ensure
      first&.release
    end
  end

  def test_cached_origin_must_match_and_dirty_hive_state_is_ignored
    with_tmp_git_repo do |repo|
      run!("git", "-C", repo, "remote", "add", "origin", repo)
      run!("git", "-C", repo, "fetch", "origin", "master:refs/remotes/origin/master", "--quiet")
      FileUtils.mkdir_p(File.join(repo, ".hive-state"))
      File.write(File.join(repo, ".hive-state", "internal.json"), "{}")

      snapshot = guard(repo).acquire!
      assert guard(repo).assert_unchanged!(snapshot)
      snapshot.release

      File.write(File.join(repo, "next.txt"), "next\n")
      run!("git", "-C", repo, "add", "next.txt")
      run!("git", "-C", repo, "commit", "-m", "next", "--quiet")
      error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) { guard(repo).acquire! }
      assert_equal "checkout_stale", error.reason
    ensure
      snapshot&.release
    end
  end

  private

  def guard(repo)
    Hive::RefactorPatrol::CheckoutGuard.new(repo, default_branch: "master")
  end
end
