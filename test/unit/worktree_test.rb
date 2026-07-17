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

  def test_create_exact_pins_the_requested_commit_without_moving_registered_head
    with_initialized_project do |dir, root|
      pinned = run!("git", "-C", dir, "rev-parse", "HEAD").strip
      File.write(File.join(dir, "later.txt"), "later\n")
      run!("git", "-C", dir, "add", ".")
      run!("git", "-C", dir, "commit", "-m", "later", "--quiet")
      registered_head = run!("git", "-C", dir, "rev-parse", "HEAD").strip
      wt = Hive::Worktree.new(dir, "exact-pinned", worktree_root: root)

      wt.create_exact!("hive-refactor/exact-pinned", base_sha: pinned)

      assert_equal pinned, run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
      assert_equal registered_head, run!("git", "-C", dir, "rev-parse", "HEAD").strip
    end
  end

  def test_create_exact_rejects_same_named_branch_outside_pinned_history
    with_initialized_project do |dir, root|
      pinned = run!("git", "-C", dir, "rev-parse", "HEAD").strip
      tree = run!("git", "-C", dir, "rev-parse", "HEAD^{tree}").strip
      unrelated = run!("git", "-C", dir, "commit-tree", tree, "-m", "unrelated root").strip
      branch = "hive-refactor/exact-conflict"
      run!("git", "-C", dir, "branch", branch, unrelated)
      wt = Hive::Worktree.new(dir, "exact-conflict", worktree_root: root)

      error = assert_raises(Hive::WorktreeError) do
        wt.create_exact!(branch, base_sha: pinned)
      end

      assert_includes error.message, "does not descend from pinned commit"
      refute wt.exists?
    end
  end

  def test_create_exact_attaches_existing_branch_that_descends_from_pinned_commit
    with_initialized_project do |dir, root|
      pinned = run!("git", "-C", dir, "rev-parse", "HEAD").strip
      File.write(File.join(dir, "later.txt"), "later\n")
      run!("git", "-C", dir, "add", ".")
      run!("git", "-C", dir, "commit", "-m", "later", "--quiet")
      descendant = run!("git", "-C", dir, "rev-parse", "HEAD").strip
      branch = "hive-refactor/exact-existing"
      run!("git", "-C", dir, "branch", branch)
      wt = Hive::Worktree.new(dir, "exact-existing", worktree_root: root)

      assert_equal :created, wt.create_exact!(branch, base_sha: pinned)
      assert_equal descendant, run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
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
      # `origin_dir` is a sibling of the per-test tmpdir, so
      # `with_tmp_dir`'s `rm_rf(dir)` never reaches it — clean it up
      # explicitly or it accumulates as a leaked `*.origin.git` bare repo.
      origin_dir = "#{dir}.origin.git"
      begin
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
      ensure
        FileUtils.rm_rf(origin_dir)
      end
    end
  end

  # Inverse of `with_origin_ahead_of_local`: advance LOCAL master past origin
  # by one commit while the dev repo's tracking ref refs/remotes/origin/master
  # stays at the pre-advance tip. Models a placeholder created via
  # `freshest_base`'s fetch-failure fallback from a local default that runs
  # ahead of a stale origin. Yields [dev_dir, worktree_root, origin_dir,
  # local_advance_sha].
  def with_local_ahead_of_origin
    with_initialized_project do |dir, root|
      origin_dir = "#{dir}.origin.git"
      begin
        run!("git", "clone", "--bare", dir, origin_dir)
        run!("git", "-C", dir, "remote", "add", "origin", origin_dir)
        # Seed the tracking ref at the shared tip, then advance only local
        # master so origin/master is genuinely behind it.
        run!("git", "-C", dir, "fetch", "origin")
        File.write(File.join(dir, "from-local.txt"), "local advance\n")
        run!("git", "-C", dir, "add", ".")
        run!("git", "-C", dir, "commit", "-m", "local-advance", "--quiet")
        local_sha = run!("git", "-C", dir, "rev-parse", "master").strip
        yield(dir, root, origin_dir, local_sha)
      ensure
        FileUtils.rm_rf(origin_dir)
      end
    end
  end

  # Push a fresh branch into `origin_dir` via a throwaway scratch clone, so a
  # branch genuinely exists on origin without the dev repo tracking it.
  def push_branch_to_origin(origin_dir, branch)
    scratch = Dir.mktmpdir("origin-pusher")
    run!("git", "clone", origin_dir, scratch)
    run!("git", "-C", scratch, "config", "user.email", "test@example.com")
    run!("git", "-C", scratch, "config", "user.name", "Test")
    run!("git", "-C", scratch, "checkout", "-b", branch)
    File.write(File.join(scratch, "#{branch}.txt"), "#{branch}\n")
    run!("git", "-C", scratch, "add", ".")
    run!("git", "-C", scratch, "commit", "-m", "#{branch} work", "--quiet")
    run!("git", "-C", scratch, "push", "origin", "#{branch}:#{branch}")
  ensure
    FileUtils.rm_rf(scratch) if scratch
  end

  # Narrow the dev repo's origin fetch refspec to ONLY the default branch, so
  # the wildcard +refs/heads/*:refs/remotes/origin/* opportunistic tracking
  # update no longer fires for other branches — reproducing a single-branch /
  # narrow-refspec clone.
  def narrow_refspec_to_default!(dir)
    run!("git", "-C", dir, "config", "remote.origin.fetch",
         "+refs/heads/master:refs/remotes/origin/master")
  end

  def push_synthetic_pull_head(origin_dir, pr_number, filename:, content:)
    scratch = Dir.mktmpdir("pull-head-pusher")
    run!("git", "clone", origin_dir, scratch)
    run!("git", "-C", scratch, "config", "user.email", "test@example.com")
    run!("git", "-C", scratch, "config", "user.name", "Test")
    File.write(File.join(scratch, filename), content)
    run!("git", "-C", scratch, "add", ".")
    run!("git", "-C", scratch, "commit", "-m", "pr #{pr_number} head", "--quiet")
    sha = run!("git", "-C", scratch, "rev-parse", "HEAD").strip
    run!("git", "-C", scratch, "push", "origin", "+HEAD:refs/pull/#{pr_number}/head")
    sha
  ensure
    FileUtils.rm_rf(scratch) if scratch
  end

  def with_synthetic_pull_origin(pr_number)
    with_tmp_git_repo do |dir|
      origin_dir = "#{dir}.origin.git"
      worktree_root = File.join(File.dirname(dir), "synthetic-pr-worktrees")
      begin
        run!("git", "clone", "--bare", dir, origin_dir)
        run!("git", "-C", dir, "remote", "add", "origin", origin_dir)
        sha = push_synthetic_pull_head(origin_dir, pr_number, filename: "pr.txt", content: "first\n")
        yield(dir, worktree_root, origin_dir, sha)
      ensure
        FileUtils.rm_rf(worktree_root)
        FileUtils.rm_rf(origin_dir)
      end
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

  def test_create_branches_from_dependency_override_when_origin_branch_exists
    with_initialized_project do |dir, root|
      origin_dir = "#{dir}.origin.git"
      scratch = nil
      begin
        run!("git", "clone", "--bare", dir, origin_dir)
        run!("git", "-C", dir, "remote", "add", "origin", origin_dir)

        scratch = Dir.mktmpdir("origin-base")
        run!("git", "clone", origin_dir, scratch)
        run!("git", "-C", scratch, "config", "user.email", "test@example.com")
        run!("git", "-C", scratch, "config", "user.name", "Test")
        run!("git", "-C", scratch, "checkout", "-b", "base-task")
        File.write(File.join(scratch, "base.txt"), "base\n")
        run!("git", "-C", scratch, "add", ".")
        run!("git", "-C", scratch, "commit", "-m", "base task", "--quiet")
        run!("git", "-C", scratch, "push", "origin", "base-task:base-task")
        base_sha = run!("git", "-C", origin_dir, "rev-parse", "base-task").strip

        wt = Hive::Worktree.new(dir, "dependent-task", worktree_root: root)
        wt.create!("dependent-task", default_branch: "master", base_override: "base-task")

        worktree_sha = `git -C #{wt.path} rev-parse HEAD`.strip
        assert_equal base_sha, worktree_sha,
                     "dependent worktree must branch from origin/<depends_on>, not default"
      ensure
        FileUtils.rm_rf(scratch) if scratch
        FileUtils.rm_rf(origin_dir)
      end
    end
  end

  def test_repoints_empty_placeholder_onto_origin_prereq
    with_initialized_project do |dir, root|
      origin_dir = "#{dir}.origin.git"
      begin
        run!("git", "clone", "--bare", dir, origin_dir)
        run!("git", "-C", dir, "remote", "add", "origin", origin_dir)
        push_branch_to_origin(origin_dir, "prereq-origin")
        prereq_sha = run!("git", "-C", origin_dir, "rev-parse", "prereq-origin").strip
        default_sha = run!("git", "-C", dir, "rev-parse", "master").strip
        run!("git", "-C", dir, "branch", "dependent-placeholder-origin", "master")

        wt = Hive::Worktree.new(dir, "dependent-placeholder-origin", worktree_root: root)
        wt.create!("dependent-placeholder-origin", default_branch: "master", base_override: "prereq-origin")

        worktree_sha = run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
        assert_equal prereq_sha, worktree_sha,
                     "empty placeholder branch must be recreated from origin/<prereq>"
        refute_equal default_sha, worktree_sha,
                     "empty placeholder branch must not stay on the default branch"
        assert File.exist?(File.join(wt.path, "prereq-origin.txt")),
               "repointed worktree must contain the prerequisite's code"
      ensure
        FileUtils.rm_rf(origin_dir)
      end
    end
  end

  def test_repoints_empty_placeholder_onto_local_prereq
    with_initialized_project do |dir, root|
      default_sha = run!("git", "-C", dir, "rev-parse", "master").strip
      run!("git", "-C", dir, "checkout", "-b", "local-prereq", "--quiet")
      File.write(File.join(dir, "local-prereq.txt"), "local prereq\n")
      run!("git", "-C", dir, "add", ".")
      run!("git", "-C", dir, "commit", "-m", "local prereq work", "--quiet")
      prereq_sha = run!("git", "-C", dir, "rev-parse", "HEAD").strip
      run!("git", "-C", dir, "checkout", "master", "--quiet")
      run!("git", "-C", dir, "branch", "dependent-placeholder-local", "master")

      wt = Hive::Worktree.new(dir, "dependent-placeholder-local", worktree_root: root)
      _, err = capture_io do
        wt.create!("dependent-placeholder-local", default_branch: "master", base_override: "local-prereq")
      end

      worktree_sha = run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
      assert_equal prereq_sha, worktree_sha,
                   "empty placeholder branch must be recreated from local <prereq> when origin is unavailable"
      refute_equal default_sha, worktree_sha,
                   "local-only dependency stacking must not collapse onto the default branch"
      assert File.exist?(File.join(wt.path, "local-prereq.txt")),
             "repointed worktree must contain the local prerequisite's code"
      assert_match(/origin\/local-prereq unavailable; stacking on local local-prereq/, err)
    end
  end

  # Regression for the tag-shadowing safeguard in `override_local_or_default`
  # (worktree.rb returns `refs/heads/<prereq>`, not a bare `<prereq>`): under
  # gitrevisions precedence a same-named `refs/tags/<prereq>` shadows
  # `refs/heads/<prereq>`, so a bare start-point would silently base the stacked
  # worktree on the tagged commit instead of the prereq branch. A reversion to
  # the bare name would make this test create the worktree at the tag's commit.
  def test_local_stack_prefers_branch_over_same_named_tag
    with_initialized_project do |dir, root|
      # Decoy commit the tag points at (distinct from the prereq branch tip).
      File.write(File.join(dir, "tagged-decoy.txt"), "tagged decoy\n")
      run!("git", "-C", dir, "add", ".")
      run!("git", "-C", dir, "commit", "-m", "tagged decoy commit", "--quiet")
      tag_sha = run!("git", "-C", dir, "rev-parse", "HEAD").strip
      run!("git", "-C", dir, "tag", "prereq-collision", tag_sha)
      run!("git", "-C", dir, "reset", "--hard", "HEAD~1", "--quiet")

      # Local branch of the SAME name at a different commit (the real prereq).
      run!("git", "-C", dir, "checkout", "-b", "prereq-collision", "--quiet")
      File.write(File.join(dir, "branch-prereq.txt"), "branch prereq\n")
      run!("git", "-C", dir, "add", ".")
      run!("git", "-C", dir, "commit", "-m", "branch prereq work", "--quiet")
      branch_sha = run!("git", "-C", dir, "rev-parse", "HEAD").strip
      run!("git", "-C", dir, "checkout", "master", "--quiet")

      refute_equal tag_sha, branch_sha,
                   "decoy tag and prereq branch must point at distinct commits for the test to bite"

      wt = Hive::Worktree.new(dir, "dependent-tag-collision", worktree_root: root)
      capture_io do
        wt.create!("dependent-tag-collision", default_branch: "master", base_override: "prereq-collision")
      end

      worktree_sha = run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
      assert_equal branch_sha, worktree_sha,
                   "the stacked base must resolve to refs/heads/<prereq>, not a same-named tag"
      refute_equal tag_sha, worktree_sha,
                   "a same-named tag must not shadow the branch as the stacked start-point"
      assert File.exist?(File.join(wt.path, "branch-prereq.txt")),
             "the stacked worktree must contain the branch prereq's code"
      refute File.exist?(File.join(wt.path, "tagged-decoy.txt")),
             "the tagged decoy commit must not become the stacked base"
    end
  end

  def test_materialize_pr_fetches_pull_head_and_adds_branch_worktree
    with_synthetic_pull_origin(42) do |dir, root, _origin_dir, sha|
      path = File.join(root, "adhoc-review-pr-42")
      result = Hive::Worktree.materialize_pr(
        repo_root: dir,
        pr_number: 42,
        path: path,
        branch: "hive/review/pr-42"
      )

      assert_equal path, result.fetch(:path)
      assert_equal "hive/review/pr-42", result.fetch(:branch)
      assert_equal sha, result.fetch(:head_sha)
      assert_equal "hive/review/pr-42", run!("git", "-C", path, "branch", "--show-current").strip
      assert_equal sha, run!("git", "-C", path, "rev-parse", "HEAD").strip
      assert File.exist?(File.join(path, "pr.txt")),
             "materialized worktree must contain the synthetic pull head"
    end
  end

  def test_materialize_pr_rerun_resets_existing_branch_when_worktree_was_removed
    with_synthetic_pull_origin(43) do |dir, root, origin_dir, _sha|
      path = File.join(root, "adhoc-review-pr-43")
      Hive::Worktree.materialize_pr(
        repo_root: dir,
        pr_number: 43,
        path: path,
        branch: "hive/review/pr-43"
      )
      run!("git", "-C", dir, "worktree", "remove", path)
      new_sha = push_synthetic_pull_head(origin_dir, 43, filename: "pr.txt", content: "second\n")

      result = Hive::Worktree.materialize_pr(
        repo_root: dir,
        pr_number: 43,
        path: path,
        branch: "hive/review/pr-43"
      )

      assert_equal new_sha, result.fetch(:head_sha)
      assert_equal new_sha, run!("git", "-C", path, "rev-parse", "HEAD").strip
      assert_equal "second\n", File.read(File.join(path, "pr.txt"))
    end
  end

  def test_materialize_pr_raises_when_fetch_fails
    with_tmp_git_repo do |dir|
      err = assert_raises(Hive::WorktreeError) do
        Hive::Worktree.materialize_pr(
          repo_root: dir,
          pr_number: 999,
          path: File.join(dir, "missing-pr-worktree"),
          branch: "hive/review/pr-999"
        )
      end

      assert_match(/git fetch origin \+pull\/999\/head:refs\/hive\/review\/pr-999 failed/, err.message)
    end
  end

  def test_materialize_pr_raises_when_head_cannot_be_resolved
    ok = Class.new { def success? = true }.new
    failed = Class.new { def success? = false }.new
    calls = []

    with_replaced_singleton_method(Open3, :capture3, lambda { |*cmd|
      calls << cmd
      cmd.include?("rev-parse") ? [ "", "bad head", failed ] : [ "", "", ok ]
    }) do
      err = assert_raises(Hive::WorktreeError) do
        Hive::Worktree.materialize_pr(
          repo_root: "/tmp/repo",
          pr_number: 44,
          path: "/tmp/worktrees/adhoc-review-pr-44",
          branch: "hive/review/pr-44"
        )
      end

      assert_match(/git rev-parse HEAD failed: bad head/, err.message)
    end

    assert calls.any? { |cmd| cmd.include?("+pull/44/head:refs/hive/review/pr-44") }
  end

  def test_materialize_pr_fetch_uses_non_interactive_env_so_it_cannot_hang_on_a_prompt
    ok = Class.new { def success? = true }.new
    fetch_env = nil

    with_replaced_singleton_method(Open3, :capture3, lambda { |*cmd|
      env = cmd.first.is_a?(Hash) ? cmd.first : {}
      fetch_env = env if cmd.include?("+pull/45/head:refs/hive/review/pr-45")
      cmd.include?("rev-parse") ? [ "abc\n", "", ok ] : [ "", "", ok ]
    }) do
      Hive::Worktree.materialize_pr(
        repo_root: "/tmp/repo",
        pr_number: 45,
        path: "/tmp/worktrees/adhoc-review-pr-45",
        branch: "hive/review/pr-45"
      )
    end

    refute_nil fetch_env, "the PR-head fetch must run through Open3.capture3 with an env hash"
    assert_equal "0", fetch_env["GIT_TERMINAL_PROMPT"],
                 "the materialize fetch must disable terminal credential prompts"
    assert_equal Hive::Worktree::NONINTERACTIVE_FETCH_ENV, fetch_env,
                 "the materialize fetch must reuse the shared non-interactive fetch env"
  end

  # Regression for the origin-ahead-of-local placeholder miss: a prior run
  # created the placeholder from origin/<default> (freshest_base), so it sits
  # at origin/master's tip while local master lags behind. Measured against
  # LOCAL master the placeholder looks like it carries the origin-ahead
  # commits (count > 0) and would be wrongly preserved; measured against
  # origin/master it is correctly empty and re-pointed onto the prerequisite.
  def test_repoints_empty_placeholder_when_origin_ahead_of_local
    with_origin_ahead_of_local do |dir, root, origin_dir, origin_sha|
      # Refresh the tracking ref so refs/remotes/origin/master reflects the
      # advanced origin tip — the helper's own fetch ran before the advance,
      # leaving the dev repo's tracking ref stale.
      run!("git", "-C", dir, "fetch", "origin", "+master:refs/remotes/origin/master")
      push_branch_to_origin(origin_dir, "prereq-ahead")
      prereq_sha = run!("git", "-C", origin_dir, "rev-parse", "prereq-ahead").strip
      # Placeholder created from origin/master (the prior freshest_base
      # result), so local master is genuinely behind the placeholder.
      run!("git", "-C", dir, "branch", "dependent-ahead", "origin/master")

      wt = Hive::Worktree.new(dir, "dependent-ahead", worktree_root: root)
      wt.create!("dependent-ahead", default_branch: "master", base_override: "prereq-ahead")

      worktree_sha = run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
      assert_equal prereq_sha, worktree_sha,
                   "an empty placeholder at origin/master (local behind) must be re-pointed onto origin/<prereq>"
      refute_equal origin_sha, worktree_sha,
                   "the placeholder must not be preserved on origin/master merely because local default lags"
      assert File.exist?(File.join(wt.path, "prereq-ahead.txt")),
             "the re-pointed worktree must contain the prerequisite's code"
    end
  end

  # Inverse regression for the origin-ahead miss: a prior run created the
  # placeholder from a LOCAL default that runs ahead of a stale origin
  # (freshest_base's fetch-failure fallback), so it sits at local master's tip
  # while refs/remotes/origin/master lags behind. Measured against ORIGIN
  # master the placeholder looks like it carries the local-ahead commit
  # (count > 0) and would be wrongly preserved; measured against local master
  # it is correctly empty and re-pointed onto the prerequisite.
  def test_repoints_empty_placeholder_when_local_ahead_of_origin
    with_local_ahead_of_origin do |dir, root, origin_dir, local_sha|
      push_branch_to_origin(origin_dir, "prereq-local-ahead")
      prereq_sha = run!("git", "-C", origin_dir, "rev-parse", "prereq-local-ahead").strip
      # Placeholder created from local master (the prior freshest_base
      # fallback), so origin/master is genuinely behind the placeholder.
      run!("git", "-C", dir, "branch", "dependent-local-ahead", "master")

      wt = Hive::Worktree.new(dir, "dependent-local-ahead", worktree_root: root)
      wt.create!("dependent-local-ahead", default_branch: "master", base_override: "prereq-local-ahead")

      worktree_sha = run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
      assert_equal prereq_sha, worktree_sha,
                   "an empty placeholder at local master (origin behind) must be re-pointed onto origin/<prereq>"
      refute_equal local_sha, worktree_sha,
                   "the placeholder must not be preserved at local master merely because origin lags"
      assert File.exist?(File.join(wt.path, "prereq-local-ahead.txt")),
             "the re-pointed worktree must contain the prerequisite's code"
    end
  end

  # `empty_placeholder?` fail-closed path #1 — no measurable ref: when a
  # nonexistent default branch leaves `default_base_refs` empty, the per-ref
  # `rev-list` loop is never entered (the `base_refs.empty?` early return fires),
  # so the branch must be preserved and attached as-is — never deleted on an
  # inconclusive check — and no WorktreeError raised. The sibling test below
  # covers the distinct path where a present base ref's own `rev-list --count`
  # measurement errors.
  def test_create_preserves_branch_when_placeholder_check_errors
    with_initialized_project do |dir, root|
      run!("git", "-C", dir, "branch", "dependent-unmeasurable", "master")
      head_sha = run!("git", "-C", dir, "rev-parse", "dependent-unmeasurable").strip

      wt = Hive::Worktree.new(dir, "dependent-unmeasurable", worktree_root: root)
      _, err = capture_io do
        wt.create!("dependent-unmeasurable", default_branch: "no-such-default", base_override: "prereq")
      end

      assert wt.exists?, "branch must survive when the placeholder measurement errors"
      worktree_sha = run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
      assert_equal head_sha, worktree_sha,
                   "an unmeasurable branch attaches as-is (fail-closed) instead of being deleted"
      assert_match(/cannot measure dependent-unmeasurable against no-such-default/, err,
                   "the no-measurable-ref fail-closed path must warn so a dropped re-point is observable")
    end
  end

  # `empty_placeholder?` fail-closed path #2 — present-but-unmeasurable ref:
  # when a default ref IS in the measurement set but its `rev-list --count`
  # exits non-zero, that ref is skipped with a warning (per-ref error arm), and
  # when no ref could be measured the branch is preserved and attached as-is
  # (all-refs-unmeasurable arm). `default_base_refs` is stubbed to return a
  # present-looking but nonexistent ref so `rev-list` errors deterministically —
  # the production trigger is a TOCTOU race or repo corruption between the
  # rev-parse existence check and the rev-list measurement.
  def test_create_preserves_branch_when_base_ref_measurement_errors
    with_initialized_project do |dir, root|
      run!("git", "-C", dir, "branch", "dependent-revlist-error", "master")
      head_sha = run!("git", "-C", dir, "rev-parse", "dependent-revlist-error").strip

      wt = Hive::Worktree.new(dir, "dependent-revlist-error", worktree_root: root)
      # Force a non-empty base-ref list whose sole ref `rev-list` cannot resolve,
      # so the per-ref error arm and then the all-refs-unmeasurable arm both fire.
      wt.define_singleton_method(:default_base_refs) do |_default_branch|
        [ "refs/heads/__no_such_base_ref__" ]
      end

      _, err = capture_io do
        wt.create!("dependent-revlist-error", default_branch: "master", base_override: "prereq")
      end

      assert wt.exists?, "branch must survive when a base ref's rev-list measurement errors"
      worktree_sha = run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
      assert_equal head_sha, worktree_sha,
                   "an unmeasurable base ref attaches the branch as-is (fail-closed) instead of deleting it"
      assert_match(%r{cannot measure dependent-revlist-error against refs/heads/__no_such_base_ref__}, err,
                   "the per-ref failure must warn so a skipped base is observable")
      assert_match(/cannot measure dependent-revlist-error against any default ref/, err,
                   "the all-refs-unmeasurable preserve path must warn")
    end
  end

  def test_preserves_branch_with_real_commits_over_override
    with_initialized_project do |dir, root|
      run!("git", "-C", dir, "checkout", "-b", "dependent-real-work", "--quiet")
      File.write(File.join(dir, "own-work.txt"), "own work\n")
      run!("git", "-C", dir, "add", ".")
      run!("git", "-C", dir, "commit", "-m", "dependent work", "--quiet")
      own_sha = run!("git", "-C", dir, "rev-parse", "HEAD").strip
      run!("git", "-C", dir, "checkout", "master", "--quiet")
      run!("git", "-C", dir, "checkout", "-b", "local-prereq-real", "--quiet")
      File.write(File.join(dir, "prereq-real.txt"), "prereq work\n")
      run!("git", "-C", dir, "add", ".")
      run!("git", "-C", dir, "commit", "-m", "prereq work", "--quiet")
      run!("git", "-C", dir, "checkout", "master", "--quiet")

      wt = Hive::Worktree.new(dir, "dependent-real-work", worktree_root: root)
      wt.create!("dependent-real-work", default_branch: "master", base_override: "local-prereq-real")

      worktree_sha = run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
      assert_equal own_sha, worktree_sha,
                   "branches with committed work must attach as-is instead of being re-pointed"
      assert File.exist?(File.join(wt.path, "own-work.txt")),
             "preserved worktree must contain the branch's own commit"
      refute File.exist?(File.join(wt.path, "prereq-real.txt")),
             "preserved worktree must not be replaced by the override base"
    end
  end

  def test_repoint_delete_failure_raises_named_error
    with_initialized_project do |dir, root|
      branch = "dependent-placeholder-busy"
      busy_parent = Dir.mktmpdir("busy-placeholder")
      busy_path = File.join(busy_parent, "checked-out")
      begin
        run!("git", "-C", dir, "branch", branch, "master")
        run!("git", "-C", dir, "worktree", "add", busy_path, branch)

        wt = Hive::Worktree.new(dir, branch, worktree_root: root)
        err = assert_raises(Hive::WorktreeError) do
          wt.create!(branch, default_branch: "master", base_override: "prereq")
        end
        assert_match(/cannot re-point empty placeholder branch #{branch}/, err.message)
        # Also assert the underlying git reason survives in the message, so a
        # regression dropping the `: #{detail}` interpolation would fail here
        # instead of shipping a bare, unactionable error.
        assert_match(/used by worktree|cannot delete/i, err.message,
                     "the raised error must carry git's underlying reason for the failed delete")
      ensure
        run!("git", "-C", dir, "worktree", "remove", "--force", busy_path) if busy_path && File.directory?(busy_path)
        FileUtils.rm_rf(busy_parent) if busy_parent
      end
    end
  end

  def test_create_falls_back_to_default_when_dependency_override_missing_on_origin
    with_initialized_project do |dir, root|
      origin_dir = "#{dir}.origin.git"
      begin
        run!("git", "clone", "--bare", dir, origin_dir)
        run!("git", "-C", dir, "remote", "add", "origin", origin_dir)
        default_sha = run!("git", "-C", origin_dir, "rev-parse", "master").strip

        wt = Hive::Worktree.new(dir, "dependent-fallback", worktree_root: root)
        _, err = capture_io do
          wt.create!("dependent-fallback", default_branch: "master", base_override: "missing-base")
        end

        worktree_sha = `git -C #{wt.path} rev-parse HEAD`.strip
        assert_equal default_sha, worktree_sha,
                     "missing dependency branch must fall back to origin/default"
        assert_match(/worktree base: fetch origin missing-base failed/, err)
      ensure
        FileUtils.rm_rf(origin_dir)
      end
    end
  end

  # `override_local_or_default` local-stack arm via the FETCH-FAILED reason.
  # The sibling test above hits the same fetch-failure with NO local prereq, so
  # it falls through to the default base. Here a local-only prereq branch (never
  # pushed to origin, so its colon-refspec fetch exits non-zero) exists, so
  # stacking must land on the local prereq rather than collapsing onto default —
  # the second of the three fallback reasons exercising the local-stack path.
  def test_stacks_on_local_prereq_when_origin_fetch_fails
    with_initialized_project do |dir, root|
      origin_dir = "#{dir}.origin.git"
      begin
        run!("git", "clone", "--bare", dir, origin_dir)
        run!("git", "-C", dir, "remote", "add", "origin", origin_dir)
        # Local-only prereq carrying its own commit; absent from origin so the
        # override fetch fails (fetch-failed reason).
        run!("git", "-C", dir, "checkout", "-b", "prereq-local-only", "--quiet")
        File.write(File.join(dir, "prereq-local-only.txt"), "local only prereq\n")
        run!("git", "-C", dir, "add", ".")
        run!("git", "-C", dir, "commit", "-m", "local-only prereq work", "--quiet")
        prereq_sha = run!("git", "-C", dir, "rev-parse", "HEAD").strip
        run!("git", "-C", dir, "checkout", "master", "--quiet")

        wt = Hive::Worktree.new(dir, "dependent-fetch-fail-local", worktree_root: root)
        _, err = capture_io do
          wt.create!("dependent-fetch-fail-local", default_branch: "master", base_override: "prereq-local-only")
        end

        worktree_sha = run!("git", "-C", wt.path, "rev-parse", "HEAD").strip
        assert_equal prereq_sha, worktree_sha,
                     "a fetch failure with a present local prereq must stack on the local prereq"
        assert File.exist?(File.join(wt.path, "prereq-local-only.txt")),
               "the stacked worktree must contain the local prerequisite's code"
        assert_match(/fetch origin prereq-local-only failed.*stacking on local prereq-local-only/m, err,
                     "the fetch-failed local-stack path must warn with the fetch-failure reason")
      ensure
        FileUtils.rm_rf(origin_dir)
      end
    end
  end

  # Real-git coverage for the open_pr/stacking guard `origin_branch_exists?`.
  # Every other test stubs it (open_pr_test.rb), so its real `fetch` +
  # `rev-parse` composition had zero coverage — an inverted boolean or wrong
  # refspec would ship green.
  def test_origin_branch_exists_true_for_pushed_branch_false_for_missing
    with_initialized_project do |dir, _root|
      origin_dir = "#{dir}.origin.git"
      scratch = nil
      begin
        run!("git", "clone", "--bare", dir, origin_dir)
        run!("git", "-C", dir, "remote", "add", "origin", origin_dir)
        push_branch_to_origin(origin_dir, "pushed-branch")

        assert Hive::Worktree.origin_branch_exists?(dir, "pushed-branch"),
               "a branch pushed to origin must be detected as existing"
        refute Hive::Worktree.origin_branch_exists?(dir, "never-pushed"),
               "a branch absent from origin must be detected as missing"
      ensure
        FileUtils.rm_rf(scratch) if scratch
        FileUtils.rm_rf(origin_dir)
      end
    end
  end

  # `local_branch_ref_exists?` gained a real caller this PR
  # (`override_local_or_default`'s local-prereq fallback), so its
  # empty/whitespace-name guard now matters: a blank base_override must
  # short-circuit to false without ever shelling out to git (an empty
  # `refs/heads/` ref-name would otherwise be a malformed query).
  def test_local_branch_ref_exists_guards_blank_names
    with_initialized_project do |dir, _root|
      refute Hive::Worktree.local_branch_ref_exists?(dir, ""),
             "empty branch name must short-circuit to false"
      refute Hive::Worktree.local_branch_ref_exists?(dir, "   "),
             "whitespace-only branch name must short-circuit to false"
      assert Hive::Worktree.local_branch_ref_exists?(dir, "master"),
             "an existing local branch must be detected as present"
    end
  end

  # Regression for the recorded FETCH_HEAD stack-collapse: on a narrow
  # (single-branch) fetch refspec, a plain `git fetch origin <branch>`
  # updates only FETCH_HEAD and never writes refs/remotes/origin/<branch>,
  # so the branch was falsely treated as missing and stacking collapsed onto
  # the default base. The colon-refspec fetch must write the tracking ref
  # deterministically. Every other override test uses the wildcard refspec
  # `git remote add origin` installs, so the suite could not catch this.
  def test_origin_branch_exists_true_under_narrow_refspec_clone
    with_initialized_project do |dir, _root|
      origin_dir = "#{dir}.origin.git"
      scratch = nil
      begin
        run!("git", "clone", "--bare", dir, origin_dir)
        run!("git", "-C", dir, "remote", "add", "origin", origin_dir)
        narrow_refspec_to_default!(dir)
        push_branch_to_origin(origin_dir, "prereq-branch")

        assert Hive::Worktree.origin_branch_exists?(dir, "prereq-branch"),
               "an existing prereq branch must be detected even under a narrow fetch refspec"
      ensure
        FileUtils.rm_rf(scratch) if scratch
        FileUtils.rm_rf(origin_dir)
      end
    end
  end

  # Narrow-refspec sibling of
  # test_create_branches_from_dependency_override_when_origin_branch_exists:
  # the dependent worktree must still branch from origin/<prereq> even when
  # the clone's fetch refspec covers only the default branch.
  def test_create_branches_from_dependency_override_under_narrow_refspec
    with_initialized_project do |dir, root|
      origin_dir = "#{dir}.origin.git"
      begin
        run!("git", "clone", "--bare", dir, origin_dir)
        run!("git", "-C", dir, "remote", "add", "origin", origin_dir)
        narrow_refspec_to_default!(dir)
        push_branch_to_origin(origin_dir, "base-task")
        base_sha = run!("git", "-C", origin_dir, "rev-parse", "base-task").strip

        wt = Hive::Worktree.new(dir, "dependent-narrow", worktree_root: root)
        wt.create!("dependent-narrow", default_branch: "master", base_override: "base-task")

        worktree_sha = `git -C #{wt.path} rev-parse HEAD`.strip
        assert_equal base_sha, worktree_sha,
                     "dependent must branch from origin/<prereq> even under a narrow fetch refspec"
      ensure
        FileUtils.rm_rf(origin_dir)
      end
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

  def test_create_falls_back_to_local_default_when_no_origin_with_base_override
    # `freshest_override_base`'s no-origin warn arm: a base_override
    # (dependency stacking) is requested but there is no origin remote, so
    # the stacked base can't be fetched — warn that it cannot stack and fall
    # back to the local default branch base. The sibling no-origin test
    # above passes no base_override, so it exercises `freshest_base`, not
    # this arm.
    with_initialized_project do |dir, root|
      local_sha = `git -C #{dir} rev-parse master`.strip
      wt = Hive::Worktree.new(dir, "dependent-no-origin", worktree_root: root)
      _, err = capture_io do
        wt.create!("dependent-no-origin", default_branch: "master", base_override: "base-task")
      end
      worktree_sha = `git -C #{wt.path} rev-parse HEAD`.strip
      assert_equal local_sha, worktree_sha,
                   "no-origin override fallback: worktree HEAD matches local master"
      assert_match(/no origin remote, origin\/base-task unavailable/, err,
                   "a dropped stack request with no origin must surface a no-origin warning")
    end
  end

  def test_create_falls_back_to_default_when_override_ref_missing_after_successful_fetch
    # `freshest_override_base`'s post-fetch ref-existence guard (the
    # `unless origin_branch_ref_exists?` arm): origin IS configured and the
    # override-branch fetch SUCCEEDS, but `origin/<override>` still does not
    # exist afterward (e.g. a server that 200s the fetch yet wrote no tracking
    # ref). This is distinct from the fetch-failure arm above — here the fetch
    # reports success, so only the ref-existence check catches the miss. The
    # branch must fall back to the default base with a "not found after fetch"
    # warning. The fetch is stubbed to report success without writing the
    # tracking ref because a real colon-refspec fetch of an absent branch
    # exits non-zero (that path is already covered by the fetch-failure test).
    with_initialized_project do |dir, root|
      origin_dir = "#{dir}.origin.git"
      begin
        run!("git", "clone", "--bare", dir, origin_dir)
        run!("git", "-C", dir, "remote", "add", "origin", origin_dir)
        origin_master_sha = run!("git", "-C", origin_dir, "rev-parse", "master").strip

        wt = Hive::Worktree.new(dir, "dependent-ghost-ref", worktree_root: root)
        # fetch_origin_branch is also called for the default branch inside
        # freshest_base; override it to report success uniformly so the
        # override fetch "succeeds" and the default fallback resolves to
        # origin/master. A real successful Process::Status stands in for the
        # fetch's exit status.
        _out, _err, ok_status = Open3.capture3("git", "-C", dir, "fetch", "origin", "master")
        Hive::Worktree.singleton_class.send(:alias_method, :__real_fetch_origin_branch, :fetch_origin_branch)
        Hive::Worktree.singleton_class.send(:alias_method, :__real_origin_branch_ref_exists?, :origin_branch_ref_exists?)
        Hive::Worktree.define_singleton_method(:fetch_origin_branch) { |_root, _branch| [ "", "", ok_status ] }
        Hive::Worktree.define_singleton_method(:origin_branch_ref_exists?) { |_root, _branch| false }

        _, err = capture_io do
          wt.create!("dependent-ghost-ref", default_branch: "master", base_override: "ghost-base")
        end
        worktree_sha = `git -C #{wt.path} rev-parse HEAD`.strip
        assert_equal origin_master_sha, worktree_sha,
                     "an override ref missing after a successful fetch must fall back to origin/default"
        assert_match(/origin\/ghost-base not found after fetch/, err,
                     "the ghost-ref fallback must surface a 'not found after fetch' warning")
      ensure
        if Hive::Worktree.singleton_class.method_defined?(:__real_fetch_origin_branch)
          Hive::Worktree.singleton_class.send(:alias_method, :fetch_origin_branch, :__real_fetch_origin_branch)
          Hive::Worktree.singleton_class.send(:alias_method, :origin_branch_ref_exists?, :__real_origin_branch_ref_exists?)
          Hive::Worktree.singleton_class.send(:remove_method, :__real_fetch_origin_branch)
          Hive::Worktree.singleton_class.send(:remove_method, :__real_origin_branch_ref_exists?)
        end
        FileUtils.rm_rf(origin_dir)
      end
    end
  end

  # `override_local_or_default` local-stack arm via the REF-MISSING-AFTER-FETCH
  # reason. The sibling ghost-ref test above hits the same reason with NO local
  # prereq and falls through to the default base; here a present local prereq
  # must be stacked on instead — the third of the three fallback reasons
  # exercising the local-stack path. Fetch is stubbed to "succeed" while
  # `origin_branch_ref_exists?` reports the ref absent, exactly as the sibling
  # test does, so only the ref-existence check drops the override.
  def test_stacks_on_local_prereq_when_origin_ref_missing_after_fetch
    with_initialized_project do |dir, root|
      origin_dir = "#{dir}.origin.git"
      begin
        run!("git", "clone", "--bare", dir, origin_dir)
        run!("git", "-C", dir, "remote", "add", "origin", origin_dir)

        # Local prereq carrying its own commit; the stubbed fetch "succeeds" but
        # the ref reads as absent, so the ref-missing reason reaches the
        # local-stack arm and finds this branch.
        run!("git", "-C", dir, "checkout", "-b", "prereq-ghost-local", "--quiet")
        File.write(File.join(dir, "prereq-ghost-local.txt"), "ghost local prereq\n")
        run!("git", "-C", dir, "add", ".")
        run!("git", "-C", dir, "commit", "-m", "ghost local prereq work", "--quiet")
        prereq_sha = run!("git", "-C", dir, "rev-parse", "HEAD").strip
        run!("git", "-C", dir, "checkout", "master", "--quiet")

        _out, _err, ok_status = Open3.capture3("git", "-C", dir, "fetch", "origin", "master")
        Hive::Worktree.singleton_class.send(:alias_method, :__real_fetch_origin_branch, :fetch_origin_branch)
        Hive::Worktree.singleton_class.send(:alias_method, :__real_origin_branch_ref_exists?, :origin_branch_ref_exists?)
        Hive::Worktree.define_singleton_method(:fetch_origin_branch) { |_root, _branch| [ "", "", ok_status ] }
        Hive::Worktree.define_singleton_method(:origin_branch_ref_exists?) { |_root, _branch| false }

        wt = Hive::Worktree.new(dir, "dependent-ghost-local", worktree_root: root)
        _, err = capture_io do
          wt.create!("dependent-ghost-local", default_branch: "master", base_override: "prereq-ghost-local")
        end

        worktree_sha = `git -C #{wt.path} rev-parse HEAD`.strip
        assert_equal prereq_sha, worktree_sha,
                     "an override ref missing after a successful fetch must stack on a present local prereq"
        assert File.exist?(File.join(wt.path, "prereq-ghost-local.txt")),
               "the stacked worktree must contain the local prerequisite's code"
        assert_match(/origin\/prereq-ghost-local not found after fetch.*stacking on local prereq-ghost-local/m, err,
                     "the ref-missing local-stack path must warn with the not-found-after-fetch reason")
      ensure
        if Hive::Worktree.singleton_class.method_defined?(:__real_fetch_origin_branch)
          Hive::Worktree.singleton_class.send(:alias_method, :fetch_origin_branch, :__real_fetch_origin_branch)
          Hive::Worktree.singleton_class.send(:alias_method, :origin_branch_ref_exists?, :__real_origin_branch_ref_exists?)
          Hive::Worktree.singleton_class.send(:remove_method, :__real_fetch_origin_branch)
          Hive::Worktree.singleton_class.send(:remove_method, :__real_origin_branch_ref_exists?)
        end
        FileUtils.rm_rf(origin_dir)
      end
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

  def test_fetch_origin_branch_uses_the_explicit_remote_head_when_a_tag_has_the_same_name
    origin = Dir.mktmpdir("hive-origin")
    seed = Dir.mktmpdir("hive-origin-seed")
    clone = Dir.mktmpdir("hive-origin-clone")
    run!("git", "init", "--bare", origin)
    run!("git", "-C", seed, "init", "-b", "master", "--quiet")
    run!("git", "-C", seed, "config", "user.email", "test@example.com")
    run!("git", "-C", seed, "config", "user.name", "Test")
    File.write(File.join(seed, "version.txt"), "tag\n")
    run!("git", "-C", seed, "add", "version.txt")
    run!("git", "-C", seed, "commit", "-m", "tag target", "--quiet")
    tag_sha = run!("git", "-C", seed, "rev-parse", "HEAD").strip
    run!("git", "-C", seed, "remote", "add", "origin", origin)
    run!("git", "-C", seed, "push", "origin", "refs/heads/master:refs/heads/master")
    run!("git", "-C", seed, "update-ref", "refs/tags/master", tag_sha)
    run!("git", "-C", seed, "push", "origin", "refs/tags/master:refs/tags/master")
    File.write(File.join(seed, "version.txt"), "branch\n")
    run!("git", "-C", seed, "add", "version.txt")
    run!("git", "-C", seed, "commit", "-m", "advance branch", "--quiet")
    branch_sha = run!("git", "-C", seed, "rev-parse", "HEAD").strip
    run!("git", "-C", seed, "push", "origin", "refs/heads/master:refs/heads/master")
    run!("git", "clone", origin, clone)
    run!("git", "-C", clone, "update-ref", "-d", "refs/remotes/origin/master")

    _out, err, status = Hive::Worktree.fetch_origin_branch(clone, "master")

    assert status.success?, err
    assert_equal branch_sha,
                 run!("git", "-C", clone, "rev-parse", "refs/remotes/origin/master").strip
    refute_equal tag_sha, branch_sha
  ensure
    FileUtils.rm_rf(origin) if origin
    FileUtils.rm_rf(seed) if seed
    FileUtils.rm_rf(clone) if clone
  end

  def test_fetch_origin_branch_times_out_and_reaps_the_transport_process_group
    with_tmp_git_repo do |repo|
      fake_bin = File.join(repo, "fake-bin")
      pid_file = File.join(repo, "ssh-pids")
      FileUtils.mkdir_p(fake_bin)
      ssh = File.join(fake_bin, "ssh")
      File.write(ssh, <<~SH)
        #!/bin/sh
        trap '' TERM
        sleep 30 &
        child=$!
        printf '%s %s\n' "$$" "$child" > "$HIVE_TEST_FETCH_PID_FILE"
        wait
      SH
      FileUtils.chmod(0o755, ssh)
      run!("git", "-C", repo, "remote", "add", "origin", "ssh://example.invalid/repo.git")

      _out, err, status = with_env(
        "PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}",
        "HIVE_TEST_FETCH_PID_FILE" => pid_file
      ) do
        Hive::Worktree.fetch_origin_branch(repo, "master", timeout_sec: 0.1)
      end

      refute status.success?
      assert_includes err, "timed out"
      pids = File.read(pid_file).split.map { |value| Integer(value, 10) }
      assert_equal 2, pids.size
      pids.each do |pid|
        process_state, _err, process_status = Open3.capture3(
          "ps", "-o", "stat=", "-p", pid.to_s
        )
        running = process_status.success? && !process_state.lstrip.start_with?("Z")
        refute running, "timed-out transport pid #{pid} must not remain running"
      end
    end
  end

  def test_fetch_origin_branch_returns_failure_for_invalid_timeout
    _out, err, status = Hive::Worktree.fetch_origin_branch("/tmp/project", "main", timeout_sec: 0)

    refute status.success?
    assert_includes err, "fetch timeout must be positive"
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
