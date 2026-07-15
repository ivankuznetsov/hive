require "test_helper"
require "hive/refactor_patrol/checkout_guard"

class HiveRefactorPatrolCheckoutGuardTest < Minitest::Test
  include HiveTestHelper

  class FakeGit
    attr_accessor :branch, :head, :local

    def initialize(root)
      @root = root
      @branch = "master"
      @head = "head"
      @local = "head"
    end

    def git_path(name) = File.join(@root, ".git", name)
    def current_branch = branch
    def detect_default_branch = "master"
    def status_short_excluding_hive_state = ""
    def head_sha = head
    def rev_parse(_ref) = local
    def remotes = []
  end

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

  def test_typed_error_generic_git_failure_local_staleness_and_pinned_movement
    assert_equal Hive::ExitCodes::TEMPFAIL,
                 Hive::RefactorPatrol::CheckoutGuard::Blocked.new("busy", "busy").exit_code

    with_tmp_git_repo do |repo|
      broken = FakeGit.new(repo)
      broken.define_singleton_method(:current_branch) { raise Hive::GitError, "broken git" }
      error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) do
        Hive::RefactorPatrol::CheckoutGuard.new(repo, default_branch: "master", git: broken).acquire!
      end
      assert_equal "checkout_unavailable", error.reason
    end

    with_tmp_git_repo do |repo|
      fake = FakeGit.new(repo)
      fake.local = "other"
      error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) do
        Hive::RefactorPatrol::CheckoutGuard.new(repo, default_branch: "master", git: fake).acquire!
      end
      assert_equal "checkout_stale", error.reason
    end

    with_tmp_git_repo do |repo|
      fake = FakeGit.new(repo)
      guarded = Hive::RefactorPatrol::CheckoutGuard.new(repo, default_branch: "master", git: fake)
      snapshot = guarded.acquire!
      fake.head = fake.local = "moved"
      error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) do
        guarded.assert_unchanged!(snapshot)
      end
      assert_equal "checkout_moved", error.reason
    ensure
      snapshot&.release
    end
  end

  def test_root_disappearing_between_checks_is_reported_as_missing
    with_tmp_dir do |dir|
      missing = File.join(dir, "gone")
      guarded = Hive::RefactorPatrol::CheckoutGuard.new(missing, default_branch: "master")
      with_replaced_singleton_method(File, :directory?, ->(path) { path == missing || FileTest.directory?(path) }) do
        error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) do
          guarded.send(:validate_root!)
        end
        assert_equal "checkout_missing", error.reason
      end
    end
  end

  private

  def guard(repo)
    Hive::RefactorPatrol::CheckoutGuard.new(repo, default_branch: "master")
  end
end
