require "test_helper"
require "hive/refactor_patrol/checkout_guard"

class RefactorPatrolCheckoutGuardTest < Minitest::Test
  include HiveTestHelper

  def test_pins_default_branch_commit_containing_merge_without_using_checkout_state
    with_tmp_git_repo do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      guard = Hive::RefactorPatrol::CheckoutGuard.new(repo, default_branch: "master")

      snapshot = guard.validate_and_snapshot!(merge_sha: head)
      assert_equal head, snapshot.fetch("analysis_sha")

      File.write(File.join(repo, "README.md"), "dirty\n")
      run!("git", "-C", repo, "switch", "--detach", "--quiet")
      dirty_snapshot = guard.validate_and_snapshot!(merge_sha: head)

      assert_equal head, dirty_snapshot.fetch("analysis_sha")
    end
  end

  def test_reuses_an_existing_pinned_analysis_commit_after_default_branch_advances
    with_tmp_git_repo do |repo|
      guard = Hive::RefactorPatrol::CheckoutGuard.new(repo, default_branch: "master")
      pinned = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      File.write(File.join(repo, "later.txt"), "later\n")
      run!("git", "-C", repo, "add", "later.txt")
      run!("git", "-C", repo, "commit", "-m", "later", "--quiet")

      snapshot = guard.validate_and_snapshot!(merge_sha: pinned, analysis_sha: pinned)

      assert_equal pinned, snapshot.fetch("analysis_sha")
    end
  end

  def test_pins_fresh_remote_default_without_moving_local_default_branch
    Dir.mktmpdir do |tmp|
      origin = File.join(tmp, "origin.git")
      run!("git", "init", "--bare", "--quiet", origin)
      with_tmp_git_repo do |repo|
        local_head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
        run!("git", "-C", repo, "remote", "add", "origin", origin)
        run!("git", "-C", repo, "push", "--quiet", "origin", "master")
        run!("git", "-C", repo, "switch", "-c", "upstream", "--quiet")
        File.write(File.join(repo, "upstream.txt"), "fresh\n")
        run!("git", "-C", repo, "add", "upstream.txt")
        run!("git", "-C", repo, "commit", "-m", "upstream", "--quiet")
        remote_head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
        run!("git", "-C", repo, "push", "--quiet", "origin", "HEAD:master")
        run!("git", "-C", repo, "switch", "master", "--quiet")
        File.write(File.join(repo, "README.md"), "dirty local checkout\n")

        snapshot = Hive::RefactorPatrol::CheckoutGuard.new(
          repo, default_branch: "master"
        ).validate_and_snapshot!(merge_sha: local_head)

        assert_equal remote_head, snapshot.fetch("analysis_sha")
        assert_equal local_head, run!("git", "-C", repo, "rev-parse", "HEAD").strip
        assert_equal "dirty local checkout\n", File.read(File.join(repo, "README.md"))
      end
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

  def test_fails_closed_for_missing_requested_analysis_commit
    with_tmp_git_repo do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip

      error = assert_raises(Hive::GitError) do
        Hive::RefactorPatrol::CheckoutGuard.new(repo, default_branch: "master")
                                          .validate_and_snapshot!(
                                            merge_sha: head,
                                            analysis_sha: "f" * 40
                                          )
      end

      assert_includes error.message, "analysis commit"
    end
  end

  def test_rejects_non_oid_analysis_commit_before_git_resolution
    with_tmp_git_repo do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip

      error = assert_raises(Hive::GitError) do
        Hive::RefactorPatrol::CheckoutGuard.new(repo, default_branch: "master")
                                          .validate_and_snapshot!(
                                            merge_sha: head,
                                            analysis_sha: "--help"
                                          )
      end

      assert_includes error.message, "full hexadecimal Git object ID"
    end
  end
end
