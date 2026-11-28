require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hive/internal_pr_checkout/git_transition"

class InternalPrCheckoutGitTransitionTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("ipc-git-transition-")
    @repo = File.join(@tmp, "repo")
    @wt = File.join(@tmp, "wt")
    FileUtils.mkdir_p(@repo)
    git(@repo, "init", "-b", "main")
    git(@repo, "config", "user.name", "Test")
    git(@repo, "config", "user.email", "test@example.com")

    File.write(File.join(@repo, ".gitignore"), "build/\n*.cache\nobstructed.txt\nobstructed_dir/\n")
    File.write(File.join(@repo, "app.rb"), "puts 'v1'\n")
    File.write(File.join(@repo, "only_a.txt"), "from a\n")
    File.write(File.join(@repo, "script.sh"), "#!/bin/sh\necho a\n")
    File.chmod(0o755, File.join(@repo, "script.sh"))
    File.symlink("app.rb", File.join(@repo, "link.rb"))
    git(@repo, "add", ".")
    git(@repo, "commit", "-m", "commit A")
    @oid_a = git(@repo, "rev-parse", "HEAD").strip

    # Create unrelated force-pushed commit B (orphan history!) with file changes,
    # deletions, executable bits, symlinks, and new files.
    git(@repo, "checkout", "--orphan", "pr-v2")
    git(@repo, "rm", "-rf", ".")
    File.write(File.join(@repo, ".gitignore"), "build/\n*.cache\nobstructed.txt\nobstructed_dir/\n")
    File.write(File.join(@repo, "app.rb"), "puts 'v2'\n")
    File.write(File.join(@repo, "only_b.txt"), "from b\n")
    File.write(File.join(@repo, "obstructed.txt"), "tracked in b\n")
    FileUtils.mkdir_p(File.join(@repo, "nested"))
    File.write(File.join(@repo, "nested", "new.txt"), "nested b\n")
    File.write(File.join(@repo, "script.sh"), "#!/bin/sh\necho b\n")
    File.chmod(0o755, File.join(@repo, "script.sh"))
    File.symlink("only_b.txt", File.join(@repo, "link.rb"))
    git(@repo, "add", "-f", ".gitignore", "app.rb", "only_b.txt", "obstructed.txt", "nested/new.txt", "script.sh", "link.rb")
    git(@repo, "commit", "-m", "commit B (unrelated history)")
    @oid_b = git(@repo, "rev-parse", "HEAD").strip

    # Create commit C where `obstructed_dir` is a tracked file (to test ignored dir collision).
    git(@repo, "checkout", "--orphan", "pr-v3")
    git(@repo, "rm", "-rf", ".")
    File.write(File.join(@repo, ".gitignore"), "build/\n*.cache\nobstructed.txt\nobstructed_dir/\n")
    File.write(File.join(@repo, "obstructed_dir"), "i am a tracked file in c\n")
    git(@repo, "add", "-f", ".gitignore", "obstructed_dir")
    git(@repo, "commit", "-m", "commit C")
    @oid_c = git(@repo, "rev-parse", "HEAD").strip

    git(@repo, "checkout", "main")
    @branch = "hive/review/pr-42"
    git(@repo, "worktree", "add", "-b", @branch, @wt, @oid_a)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_clean_unrelated_history_transition_preserves_unrelated_ignored_build_cache
    FileUtils.mkdir_p(File.join(@wt, "build"))
    File.write(File.join(@wt, "build", "artifact.o"), "cached-bytes")

    from_tree = Hive::InternalPrCheckout::GitTransition.capture_tree_snapshot(@wt, @oid_a)
    to_tree = Hive::InternalPrCheckout::GitTransition.capture_tree_snapshot(@wt, @oid_b)

    assert Hive::InternalPrCheckout::GitTransition.transition_clean!(
      worktree_path: @wt,
      branch: @branch,
      from_oid: @oid_a,
      to_oid: @oid_b,
      from_tree: from_tree,
      to_tree: to_tree
    )

    assert_equal @oid_b, git(@wt, "rev-parse", "HEAD").strip
    assert_equal @branch, git(@wt, "symbolic-ref", "--short", "HEAD").strip
    assert_equal "puts 'v2'\n", File.read(File.join(@wt, "app.rb"))
    assert_equal "from b\n", File.read(File.join(@wt, "only_b.txt"))
    refute File.exist?(File.join(@wt, "only_a.txt"))
    assert_equal "only_b.txt", File.readlink(File.join(@wt, "link.rb"))
    assert_equal "cached-bytes", File.read(File.join(@wt, "build", "artifact.o"))
  end

  def test_ignored_file_and_directory_obstructions_block_forward_and_restore_without_overwriting_bytes
    # 1. Forward ignored file obstruction
    File.write(File.join(@wt, "obstructed.txt"), "precious local ignored secret\n")
    from_tree = Hive::InternalPrCheckout::GitTransition.capture_tree_snapshot(@wt, @oid_a)
    to_tree = Hive::InternalPrCheckout::GitTransition.capture_tree_snapshot(@wt, @oid_b)

    err = assert_raises(Hive::InternalPrCheckout::Error) do
      Hive::InternalPrCheckout::GitTransition.transition_clean!(
        worktree_path: @wt, branch: @branch, from_oid: @oid_a, to_oid: @oid_b,
        from_tree: from_tree, to_tree: to_tree
      )
    end
    assert_equal "checkout_dirty", err.reason
    assert_equal "precious local ignored secret\n", File.read(File.join(@wt, "obstructed.txt"))
    assert_equal @oid_a, git(@wt, "rev-parse", "HEAD").strip
    File.unlink(File.join(@wt, "obstructed.txt"))

    # 2. Forward ignored directory obstruction (where commit C has a tracked file named `obstructed_dir`)
    FileUtils.mkdir_p(File.join(@wt, "obstructed_dir"))
    File.write(File.join(@wt, "obstructed_dir", "local.bin"), "keep-me")
    tree_c = Hive::InternalPrCheckout::GitTransition.capture_tree_snapshot(@wt, @oid_c)

    err = assert_raises(Hive::InternalPrCheckout::Error) do
      Hive::InternalPrCheckout::GitTransition.transition_clean!(
        worktree_path: @wt, branch: @branch, from_oid: @oid_a, to_oid: @oid_c,
        from_tree: from_tree, to_tree: tree_c
      )
    end
    assert_equal "checkout_dirty", err.reason
    assert_equal "keep-me", File.read(File.join(@wt, "obstructed_dir", "local.bin"))
    assert_equal @oid_a, git(@wt, "rev-parse", "HEAD").strip
    FileUtils.rm_rf(File.join(@wt, "obstructed_dir"))

    # 3. Reverse/restore ignored obstruction: move cleanly to B, drop an ignored
    #    file named `only_a.txt` (via .git/info/exclude so it is ignored in B),
    #    and verify restore back to A refuses and keeps original bytes!
    Hive::InternalPrCheckout::GitTransition.transition_clean!(
      worktree_path: @wt, branch: @branch, from_oid: @oid_a, to_oid: @oid_b,
      from_tree: from_tree, to_tree: to_tree
    )
    common_dir = git(@wt, "rev-parse", "--git-common-dir").strip
    FileUtils.mkdir_p(File.join(common_dir, "info"))
    File.write(File.join(common_dir, "info", "exclude"), "only_a.txt\n")
    File.write(File.join(@wt, "only_a.txt"), "operator-precious-on-restore")

    err = assert_raises(Hive::InternalPrCheckout::Error) do
      Hive::InternalPrCheckout::GitTransition.verify_and_converge!(
        worktree_path: @wt, branch: @branch, from_oid: @oid_a, to_oid: @oid_b, dest_oid: @oid_a
      )
    end
    assert_equal "checkout_dirty", err.reason
    assert_equal "operator-precious-on-restore", File.read(File.join(@wt, "only_a.txt"))
    assert_equal @oid_b, git(@wt, "rev-parse", "HEAD").strip
  end

  def test_mid_checkout_mixed_state_recovers_forward_and_backward_preserving_ignored_cache
    FileUtils.mkdir_p(File.join(@wt, "build"))
    File.write(File.join(@wt, "build", "keep.o"), "build-cache")

    # Simulate a killed checkout halfway between A and B:
    # HEAD detached at A, branch still at A, `app.rb` already at B's content,
    # `only_a.txt` still present from A, `only_b.txt` written from B.
    git(@wt, "checkout", "--detach", @oid_a)
    File.write(File.join(@wt, "app.rb"), "puts 'v2'\n")
    File.write(File.join(@wt, "only_b.txt"), "from b\n")
    File.write(File.join(@wt, "obstructed.txt"), "tracked in b\n")

    assert Hive::InternalPrCheckout::GitTransition.verify_and_converge!(
      worktree_path: @wt, branch: @branch, from_oid: @oid_a, to_oid: @oid_b, dest_oid: @oid_b
    )
    assert_equal @oid_b, git(@wt, "rev-parse", "HEAD").strip
    assert_equal @branch, git(@wt, "symbolic-ref", "--short", "HEAD").strip
    refute File.exist?(File.join(@wt, "only_a.txt"))
    assert_equal "build-cache", File.read(File.join(@wt, "build", "keep.o"))

    # Now simulate a killed rollback halfway from B back to A:
    git(@wt, "checkout", "--detach", @oid_b)
    File.write(File.join(@wt, "app.rb"), "puts 'v1'\n")
    File.write(File.join(@wt, "only_a.txt"), "from a\n")

    assert Hive::InternalPrCheckout::GitTransition.verify_and_converge!(
      worktree_path: @wt, branch: @branch, from_oid: @oid_a, to_oid: @oid_b, dest_oid: @oid_a
    )
    assert_equal @oid_a, git(@wt, "rev-parse", "HEAD").strip
    assert_equal @branch, git(@wt, "symbolic-ref", "--short", "HEAD").strip
    refute File.exist?(File.join(@wt, "only_b.txt"))
    assert_equal "build-cache", File.read(File.join(@wt, "build", "keep.o"))
  end

  def test_third_state_untracked_file_and_unexplained_lock_block_recovery
    # 1. Third tracked state in worktree
    git(@wt, "checkout", "--detach", @oid_a)
    File.write(File.join(@wt, "app.rb"), "operator third edit\n")
    err = assert_raises(Hive::InternalPrCheckout::Error) do
      Hive::InternalPrCheckout::GitTransition.verify_and_converge!(
        worktree_path: @wt, branch: @branch, from_oid: @oid_a, to_oid: @oid_b, dest_oid: @oid_b
      )
    end
    assert_equal "checkout_dirty", err.reason
    assert_equal "operator third edit\n", File.read(File.join(@wt, "app.rb"))
    File.write(File.join(@wt, "app.rb"), "puts 'v1'\n")

    # 2. Non-ignored untracked file
    File.write(File.join(@wt, "scratch.txt"), "do not lose me\n")
    err = assert_raises(Hive::InternalPrCheckout::Error) do
      Hive::InternalPrCheckout::GitTransition.verify_and_converge!(
        worktree_path: @wt, branch: @branch, from_oid: @oid_a, to_oid: @oid_b, dest_oid: @oid_b
      )
    end
    assert_equal "checkout_dirty", err.reason
    assert_equal "do not lose me\n", File.read(File.join(@wt, "scratch.txt"))
    File.unlink(File.join(@wt, "scratch.txt"))

    # 3. Unexplained Git lock
    wt_git_dir = git(@wt, "rev-parse", "--git-dir").strip
    lock_file = File.join(wt_git_dir, "index.lock")
    File.write(lock_file, "")
    err = assert_raises(Hive::InternalPrCheckout::Error) do
      Hive::InternalPrCheckout::GitTransition.verify_and_converge!(
        worktree_path: @wt, branch: @branch, from_oid: @oid_a, to_oid: @oid_b, dest_oid: @oid_b
      )
    end
    assert_equal "git_residue_unverifiable", err.reason
    File.unlink(lock_file)
  end

  private

  def git(dir, *args)
    out, err, status = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end
end
