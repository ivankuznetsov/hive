require "test_helper"
require "hive/config"
require "hive/git_ops"
require "hive/worktree"

class WorktreeTest < Minitest::Test
  include HiveTestHelper

  def with_initialized_project
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      ops.add_hive_state_to_master_gitignore!
      worktree_root = File.join(File.dirname(dir), "#{File.basename(dir)}.worktrees")
      FileUtils.mkdir_p(worktree_root)
      yield(dir, worktree_root)
    ensure
      worktree_root = File.join(File.dirname(dir), "#{File.basename(dir)}.worktrees") if dir
      FileUtils.rm_rf(worktree_root) if worktree_root && File.exist?(worktree_root)
    end
  end

  def test_create_worktree_makes_branch_and_dir
    with_initialized_project do |dir, root|
      wt = Hive::Worktree.new(dir, "feat-x", worktree_root: root)
      wt.create!("feat-x", default_branch: "master")
      assert wt.exists?
      branch = `git -C #{wt.path} branch --show-current`.strip
      assert_equal "feat-x", branch
      refute File.directory?(File.join(wt.path, ".hive-state")),
             ".hive-state must not appear in feature worktree (master gitignores it)"
    end
  end

  def test_attaches_to_existing_branch
    with_initialized_project do |dir, root|
      wt1 = Hive::Worktree.new(dir, "feat-y", worktree_root: root)
      wt1.create!("feat-y", default_branch: "master")
      wt1.remove!
      wt2 = Hive::Worktree.new(dir, "feat-y", worktree_root: root)
      wt2.create!("feat-y", default_branch: "master")
      assert wt2.exists?
    end
  end

  def test_create_fails_on_double_create
    with_initialized_project do |dir, root|
      wt = Hive::Worktree.new(dir, "feat-z", worktree_root: root)
      wt.create!("feat-z", default_branch: "master")
      assert_raises(Hive::WorktreeError) do
        Hive::Worktree.new(dir, "feat-z", worktree_root: root).create!("feat-z", default_branch: "master")
      end
    end
  end

  def test_remove_clears_path_from_list
    with_initialized_project do |dir, root|
      wt = Hive::Worktree.new(dir, "feat-r", worktree_root: root)
      wt.create!("feat-r", default_branch: "master")
      wt.remove!
      refute_includes wt.list_worktree_paths, wt.path
    end
  end

  def test_pointer_validation_blocks_path_traversal
    Dir.mktmpdir do |root|
      assert_raises(Hive::WorktreeError) do
        Hive::Worktree.validate_pointer_path("/etc", root)
      end
      ok = Hive::Worktree.validate_pointer_path("#{root}/inside", root)
      assert_equal "#{root}/inside", ok
    end
  end

  def test_worktree_root_uses_project_config_when_not_overridden
    Dir.mktmpdir do |dir|
      hive_state = File.join(dir, ".hive-state")
      configured_root = File.join(dir, "configured-worktrees")
      FileUtils.mkdir_p(hive_state)
      File.write(File.join(hive_state, "config.yml"), { "worktree_root" => configured_root }.to_yaml)

      wt = Hive::Worktree.new(dir, "feat-configured")

      assert_equal configured_root, wt.worktree_root
      assert_equal File.join(configured_root, "feat-configured"), wt.path
    end
  end

  # Set up `origin` as a bare clone of the dev repo, push master to it,
  # then advance origin by one commit so local master is one commit
  # behind origin/master. Returns [dev_dir, worktree_root, origin_dir,
  # origin_advance_sha] for the test body to assert against.
  def with_origin_ahead_of_local
    with_initialized_project do |dir, root|
      origin_dir = "#{dir}.origin.git"
      run!("git", "clone", "--bare", dir, origin_dir)
      run!("git", "-C", dir, "remote", "add", "origin", origin_dir)
      run!("git", "-C", dir, "fetch", "origin")
      # Advance origin: clone the bare into a scratch worktree, add a
      # commit, push back. This simulates someone else pushing to
      # origin while local master sits still.
      scratch = Dir.mktmpdir("origin-pusher")
      begin
        run!("git", "clone", origin_dir, scratch)
        # CI runners don't have global git identity; configure
        # locally so the commit lands without prompting.
        run!("git", "-C", scratch, "config", "user.email", "test@example.com")
        run!("git", "-C", scratch, "config", "user.name", "Test")
        File.write(File.join(scratch, "from-origin.txt"), "advanced\n")
        run!("git", "-C", scratch, "add", ".")
        run!("git", "-C", scratch, "commit", "-m", "origin-advance", "--quiet")
        run!("git", "-C", scratch, "push", "origin", "master:master")
      ensure
        FileUtils.rm_rf(scratch)
      end
      origin_sha = `git -C #{origin_dir} rev-parse master`.strip
      yield(dir, root, origin_dir, origin_sha)
    end
  end

  def test_create_branches_from_origin_default_when_origin_ahead_of_local
    # Regression for the agent-plugins-was-7-commits-behind incident:
    # creating a worktree must branch from origin/<default>'s current
    # tip, not from local <default>. Without the fetch+origin/ base
    # the new worktree silently misses upstream commits and reviewers
    # surface them as phantom deletions.
    with_origin_ahead_of_local do |dir, root, _origin_dir, origin_sha|
      wt = Hive::Worktree.new(dir, "feat-fresh", worktree_root: root)
      wt.create!("feat-fresh", default_branch: "master")

      worktree_sha = `git -C #{wt.path} rev-parse HEAD`.strip
      assert_equal origin_sha, worktree_sha,
                   "new worktree's HEAD must match origin/master, not stale local master"
    end
  end

  def test_create_falls_back_to_local_default_when_no_origin_remote
    # No `origin` configured — the existing behavior (branch from
    # local default) is the correct fallback. Must not raise.
    with_initialized_project do |dir, root|
      local_sha = `git -C #{dir} rev-parse master`.strip
      wt = Hive::Worktree.new(dir, "feat-no-remote", worktree_root: root)
      wt.create!("feat-no-remote", default_branch: "master")
      worktree_sha = `git -C #{wt.path} rev-parse HEAD`.strip
      assert_equal local_sha, worktree_sha,
                   "no-origin fallback: worktree HEAD matches local master"
    end
  end

  def test_create_falls_back_to_local_when_fetch_fails
    # Origin remote configured but unreachable — fetch fails, fallback
    # to local <default> with a stderr warning. The worktree must
    # still be created (no raise) so the operator can still work
    # offline.
    with_initialized_project do |dir, root|
      run!("git", "-C", dir, "remote", "add", "origin", "https://nonexistent.invalid/repo.git")
      local_sha = `git -C #{dir} rev-parse master`.strip
      wt = Hive::Worktree.new(dir, "feat-no-net", worktree_root: root)
      _, err = capture_io { wt.create!("feat-no-net", default_branch: "master") }
      worktree_sha = `git -C #{wt.path} rev-parse HEAD`.strip
      assert_equal local_sha, worktree_sha,
                   "fetch-failure fallback: worktree HEAD matches local master"
      assert_match(/worktree base: fetch origin master failed/, err,
                   "fetch failure must surface a stderr warning so the operator knows")
    end
  end

  # Plan R12: drop must converge even when worktree.yml has been
  # truncated, hand-edited, or corrupted by a crashed prior writer.
  # read_pointer treats parse failure as "no pointer" (returns nil)
  # so the caller falls through to the derived path.
  def test_read_pointer_returns_nil_for_malformed_yaml
    Dir.mktmpdir do |folder|
      File.write(File.join(folder, "worktree.yml"), "path: [unterminated\n")
      assert_nil Hive::Worktree.read_pointer(folder),
                 "malformed worktree.yml must produce nil, not raise Psych::SyntaxError"
    end
  end

  def test_read_pointer_returns_nil_when_file_missing
    Dir.mktmpdir do |folder|
      assert_nil Hive::Worktree.read_pointer(folder)
    end
  end

  def test_read_pointer_raises_worktree_error_for_non_hash_root
    Dir.mktmpdir do |folder|
      File.write(File.join(folder, "worktree.yml"), "just a string\n")
      assert_raises(Hive::WorktreeError) do
        Hive::Worktree.read_pointer(folder)
      end
    end
  end

  # `Worktree.canonical_root` resolves the per-project worktree_root
  # override, falling back to `~/Dev/<repo>.worktrees`. Drop calls
  # this via `Hive::Worktree.canonical_root` instead of duplicating
  # the formula so a future override fallback change has one home.
  def test_canonical_root_uses_per_project_override_when_set
    with_initialized_project do |dir, root|
      File.write(
        File.join(dir, ".hive-state", "config.yml"),
        { "worktree_root" => root }.to_yaml
      )
      assert_equal File.expand_path(root), Hive::Worktree.canonical_root(dir)
    end
  end

  def test_master_log_clean_after_feature_commits
    with_initialized_project do |dir, root|
      wt = Hive::Worktree.new(dir, "feat-q", worktree_root: root)
      wt.create!("feat-q", default_branch: "master")
      File.write(File.join(wt.path, "newfile.txt"), "x\n")
      `git -C #{wt.path} add . && git -C #{wt.path} -c user.email=t@t -c user.name=t commit -m "feat-q work"`
      hive_msgs = `git -C #{dir} log --format=%s master`.strip.split("\n").select { |m| m.start_with?("hive:") }
      assert_empty hive_msgs
    end
  end
end
