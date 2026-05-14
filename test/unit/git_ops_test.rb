require "test_helper"
require "hive/git_ops"

class GitOpsTest < Minitest::Test
  include HiveTestHelper

  def test_default_branch_from_local_head
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      assert_equal "master", ops.default_branch
    end
  end

  def test_default_branch_falls_back_to_master_constant
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      branch = ops.default_branch
      refute_empty branch
    end
  end

  def test_hive_state_init_creates_orphan_branch_and_worktree
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      assert_equal :created, ops.hive_state_init
      assert ops.hive_state_branch_exists?, "hive/state branch should exist"
      assert File.directory?(File.join(dir, ".hive-state")), ".hive-state worktree should be created"
      Hive::Stages::DIRS.each do |stage|
        assert File.directory?(File.join(dir, ".hive-state", "stages", stage)),
               "stage dir #{stage} should exist"
      end
      log = `git -C #{dir} log --format=%s hive/state`.strip
      assert_includes log, "hive: bootstrap"
    end
  end

  def test_hive_state_init_idempotent
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      assert_equal :existed, ops.hive_state_init, "second init should report :existed"
    end
  end

  def test_add_hive_state_to_master_gitignore
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      assert_equal :added, ops.add_hive_state_to_master_gitignore!
      content = File.read(File.join(dir, ".gitignore"))
      assert_includes content, "/.hive-state/"
      assert_equal :already, ops.add_hive_state_to_master_gitignore!, "should be idempotent on re-run"
    end
  end

  def test_hive_commit_creates_commit_when_diff_present
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      task_dir = File.join(dir, ".hive-state", "stages", "1-inbox", "foo-260424-aaaa")
      FileUtils.mkdir_p(task_dir)
      File.write(File.join(task_dir, "idea.md"), "# Foo\n<!-- WAITING -->\n")
      result = ops.hive_commit(stage_name: "1-inbox", slug: "foo-260424-aaaa", action: "captured")
      assert_equal :committed, result
      log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
      assert_equal "hive: 1-inbox/foo-260424-aaaa captured", log
    end
  end

  def test_hive_commit_skips_when_diff_empty
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      result = ops.hive_commit(stage_name: "1-inbox", slug: "x", action: "noop")
      assert_equal :nothing_to_commit, result
    end
  end

  def test_master_log_unaffected_by_hive_commits
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      ops.add_hive_state_to_master_gitignore!
      File.write(File.join(dir, ".hive-state", "stages", "1-inbox", "x.md"), "x")
      ops.hive_commit(stage_name: "1-inbox", slug: "x", action: "captured")

      master_log = `git -C #{dir} log --format=%s master`.strip.split("\n")
      hive_msgs = master_log.select { |m| m.start_with?("hive:") }
      assert_empty hive_msgs, "master must not contain hive: commits"
    end
  end

  # ---- Rebase plumbing (U1 of the auto-rebase plan) ----

  # Set up a "feature branch behind master" scenario in a tmp git repo.
  # Returns the path; the repo has:
  #   - master at HEAD with 3 extra commits after the branch point
  #   - feature branch checked out, 0 commits ahead, 3 behind master
  # No remote — for tests that don't need fetch behavior.
  def with_feature_branch_behind_master
    with_tmp_git_repo do |dir|
      run!("git", "-C", dir, "checkout", "-b", "feature")
      run!("git", "-C", dir, "checkout", "master")
      3.times do |i|
        File.write(File.join(dir, "main-#{i}.txt"), "main commit #{i}\n")
        run!("git", "-C", dir, "add", ".")
        run!("git", "-C", dir, "commit", "-m", "main-#{i}", "--quiet")
      end
      run!("git", "-C", dir, "checkout", "feature")
      yield(dir)
    end
  end

  def test_commits_behind_returns_count_for_branch_behind_master
    with_feature_branch_behind_master do |dir|
      ops = Hive::GitOps.new(dir)
      assert_equal 3, ops.commits_behind("master"),
                   "feature branch is 3 commits behind master"
    end
  end

  def test_commits_behind_returns_zero_for_no_drift
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      assert_equal 0, ops.commits_behind("master"),
                   "HEAD on master has no drift against itself"
    end
  end

  def test_commits_behind_returns_zero_for_unknown_ref
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      assert_equal 0, ops.commits_behind("origin/does-not-exist"),
                   "unknown ref must not raise; fail-soft fallback"
    end
  end

  def test_fetch_default_branch_returns_false_on_unreachable_remote
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      # No `origin` remote configured; fetch must return false, not raise.
      refute ops.fetch_default_branch("master"),
             "fetch against missing remote returns false (fail-soft)"
    end
  end

  def test_fetch_default_branch_uses_non_interactive_env
    # The env-var injection (GIT_TERMINAL_PROMPT=0, BatchMode SSH) is
    # what prevents fetch hangs in production. Without unit-testing
    # the actual subprocess env (which is brittle), we at least pin
    # that fetch_default_branch DOES NOT hang on a misconfigured
    # remote (e.g., bogus HTTPS URL that would otherwise prompt).
    with_tmp_git_repo do |dir|
      run!("git", "-C", dir, "remote", "add", "origin", "https://nonexistent.invalid/repo.git")
      ops = Hive::GitOps.new(dir)
      # Returns within a few seconds, not hanging on cred prompt.
      refute ops.fetch_default_branch("master")
    end
  end

  def test_dirty_returns_true_for_uncommitted_changes
    with_tmp_git_repo do |dir|
      File.write(File.join(dir, "uncommitted.txt"), "x")
      ops = Hive::GitOps.new(dir)
      assert ops.dirty?, "uncommitted file makes worktree dirty"
    end
  end

  def test_dirty_returns_false_for_clean_worktree
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      refute ops.dirty?, "freshly committed worktree is clean"
    end
  end

  def test_detached_head_returns_true_on_detached_head
    with_tmp_git_repo do |dir|
      sha = `git -C #{dir} rev-parse HEAD`.strip
      run!("git", "-C", dir, "checkout", "--detach", sha)
      ops = Hive::GitOps.new(dir)
      assert ops.detached_head?, "detached checkout makes detached_head? true"
    end
  end

  def test_detached_head_returns_false_on_normal_branch
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      refute ops.detached_head?, "checked-out branch is NOT detached"
    end
  end

  def test_rebase_in_progress_false_on_clean_worktree
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      refute ops.rebase_in_progress?, "no rebase active on a fresh worktree"
    end
  end

  def test_rebase_onto_fast_forward_succeeds
    with_feature_branch_behind_master do |dir|
      ops = Hive::GitOps.new(dir)
      master_sha = `git -C #{dir} rev-parse master`.strip
      assert ops.rebase_onto("master"), "fast-forward rebase succeeds"
      assert_equal master_sha, ops.head_sha,
                   "HEAD advances to master after fast-forward rebase"
      refute ops.rebase_in_progress?, "no rebase state after clean completion"
    end
  end

  def test_rebase_onto_raises_git_error_for_unknown_ref
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      assert_raises(Hive::GitError) { ops.rebase_onto("does-not-exist") }
      # And NOT RebaseConflict — that's reserved for actual conflict halts.
      refute ops.rebase_in_progress?, "unknown-ref failure leaves no rebase state"
    end
  end

  def test_rebase_onto_raises_rebase_conflict_on_real_conflict
    # Set up: master and feature both edit the SAME line of the SAME
    # file → rebase produces a real conflict.
    with_tmp_git_repo do |dir|
      File.write(File.join(dir, "shared.txt"), "original\n")
      run!("git", "-C", dir, "add", ".")
      run!("git", "-C", dir, "commit", "-m", "shared baseline", "--quiet")

      run!("git", "-C", dir, "checkout", "-b", "feature")
      File.write(File.join(dir, "shared.txt"), "feature-edit\n")
      run!("git", "-C", dir, "commit", "-am", "feature edit", "--quiet")

      run!("git", "-C", dir, "checkout", "master")
      File.write(File.join(dir, "shared.txt"), "master-edit\n")
      run!("git", "-C", dir, "commit", "-am", "master edit", "--quiet")

      run!("git", "-C", dir, "checkout", "feature")
      ops = Hive::GitOps.new(dir)

      assert_raises(Hive::RebaseConflict) { ops.rebase_onto("master") }
      assert ops.rebase_in_progress?, "rebase state on disk after conflict"
      refute_empty ops.staged_unmerged_files,
                   "unmerged files surface in staged_unmerged_files"
      assert_includes ops.staged_unmerged_files, "shared.txt"
    end
  end

  def test_rebase_abort_restores_pre_rebase_head
    # Same conflict setup as above, then abort.
    with_tmp_git_repo do |dir|
      File.write(File.join(dir, "shared.txt"), "original\n")
      run!("git", "-C", dir, "add", ".")
      run!("git", "-C", dir, "commit", "-m", "shared", "--quiet")

      run!("git", "-C", dir, "checkout", "-b", "feature")
      File.write(File.join(dir, "shared.txt"), "feature-edit\n")
      run!("git", "-C", dir, "commit", "-am", "feature edit", "--quiet")
      feature_sha = `git -C #{dir} rev-parse HEAD`.strip

      run!("git", "-C", dir, "checkout", "master")
      File.write(File.join(dir, "shared.txt"), "master-edit\n")
      run!("git", "-C", dir, "commit", "-am", "master edit", "--quiet")

      run!("git", "-C", dir, "checkout", "feature")
      ops = Hive::GitOps.new(dir)
      assert_raises(Hive::RebaseConflict) { ops.rebase_onto("master") }
      assert ops.rebase_abort, "rebase_abort succeeds"
      refute ops.rebase_in_progress?, "rebase state cleared after abort"
      assert_equal feature_sha, ops.head_sha,
                   "HEAD restored to pre-rebase commit"
    end
  end

  def test_reset_hard_orig_head_cleans_post_abort_state
    # ORIG_HEAD is set by git at the start of any rebase. After an
    # abort, reset --hard ORIG_HEAD is a no-op for tracked files but
    # clears any agent-created untracked state.
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      # Set ORIG_HEAD by faking a rebase setup (the test doesn't need
      # a real rebase — git tooling sets ORIG_HEAD on reset/merge too).
      run!("git", "-C", dir, "update-ref", "ORIG_HEAD", "HEAD")
      assert ops.reset_hard_orig_head, "reset --hard ORIG_HEAD succeeds when ORIG_HEAD exists"
    end
  end

  def test_staged_unmerged_files_returns_empty_when_no_rebase
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      assert_equal [], ops.staged_unmerged_files
    end
  end

  # ---- PR #69 review B1 + B2 fixes ----

  def test_rebase_merge_message_path_returns_nil_when_no_rebase
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      assert_nil ops.rebase_merge_message_path
    end
  end

  def test_rebase_merge_message_path_resolves_via_rev_parse_git_dir
    # B1: previously the path was hardcoded as
    # `<project_root>/.git/rebase-merge/message`. That breaks in
    # linked worktrees where `.git` is a FILE pointing at the real
    # gitdir. The new helper uses `git rev-parse --git-dir` so it
    # works in both regular repos and linked worktrees. This test
    # forces the conflict state with a real conflict so the path
    # actually exists.
    with_tmp_git_repo do |dir|
      File.write(File.join(dir, "shared.txt"), "v0\n")
      run!("git", "-C", dir, "add", ".")
      run!("git", "-C", dir, "commit", "-m", "baseline", "--quiet")

      run!("git", "-C", dir, "checkout", "-b", "feature")
      File.write(File.join(dir, "shared.txt"), "feature\n")
      run!("git", "-C", dir, "commit", "-am", "feature", "--quiet")

      run!("git", "-C", dir, "checkout", "master")
      File.write(File.join(dir, "shared.txt"), "master\n")
      run!("git", "-C", dir, "commit", "-am", "master", "--quiet")

      run!("git", "-C", dir, "checkout", "feature")
      ops = Hive::GitOps.new(dir)
      assert_raises(Hive::RebaseConflict) { ops.rebase_onto("master") }

      msg_path = ops.rebase_merge_message_path
      refute_nil msg_path, "rebase_merge_message_path returns a path when rebase is in progress"
      assert File.file?(msg_path), "the resolved path must exist as a regular file"
      content = File.read(msg_path)
      refute_empty content.strip, "commit message file is non-empty"
    end
  end

  # ---- run_git_with_timeout (PR #69 reliability #4 + #11) ----

  def test_run_git_with_timeout_returns_success_on_clean_exit
    # `git --version` is a fast, side-effect-free command. Verifies
    # the happy path: success=true, timed_out=false.
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      success, _err, timed_out = ops.run_git_with_timeout([ "git", "--version" ])
      assert success, "git --version exits 0"
      refute timed_out, "timed_out must be false on clean exit"
    end
  end

  def test_run_git_with_timeout_captures_nonzero_exit
    # An invalid git subcommand exits non-zero. Should return
    # success=false, no timeout flag.
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      success, err, timed_out = ops.run_git_with_timeout(
        [ "git", "-C", dir, "nope-not-a-real-subcommand" ]
      )
      refute success, "invalid subcommand returns success=false"
      refute timed_out, "timed_out=false when the process exits on its own"
      refute_empty err, "stderr should be captured"
    end
  end

  def test_run_git_with_timeout_fires_on_slow_subprocess
    # Use `sleep` (not git) — same code path, deterministic stall.
    # 1-second deadline against a 30-second sleep proves the
    # SIGTERM→SIGKILL escalation reaps the child.
    skip "/bin/sleep unavailable" unless File.executable?("/bin/sleep") || File.executable?("/usr/bin/sleep")
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      success, _err, timed_out = ops.run_git_with_timeout([ "sleep", "30" ], timeout_sec: 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start
      refute success, "timed-out command must report success=false"
      assert timed_out, "timed_out must be true when wall-clock budget elapses"
      assert elapsed < 5, "must reap the child quickly (< 5s); took #{elapsed}s — escalation path broken"
    end
  end

  def test_run_git_with_timeout_caps_captured_output
    # A subprocess that floods stderr should be capped at max_bytes
    # rather than buffered without bound. Use a tiny inline ruby
    # writer for portability (no /bin/yes assumption).
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      # Write ~64 KiB to stderr fast then exit 1. Capture is bounded
      # to 1 KiB; the cap must hold even though the producer emits
      # 64x more.
      success, err, _timed_out = ops.run_git_with_timeout(
        [ "ruby", "-e", "STDERR.write('x' * 65536); exit 1" ],
        max_bytes: 1024
      )
      refute success
      assert err.bytesize <= 1024,
             "stderr capture must be capped at max_bytes (got #{err.bytesize} bytes)"
    end
  end

  def test_reset_hard_orig_head_also_runs_git_clean
    # B2: reset --hard ORIG_HEAD does NOT remove untracked files;
    # the cleanup combo IS reset + clean -fd. This test pins that
    # `reset_hard_orig_head` actually cleans untracked artifacts
    # (which the wiki/plan claim earlier was wrong about).
    with_tmp_git_repo do |dir|
      run!("git", "-C", dir, "update-ref", "ORIG_HEAD", "HEAD")
      untracked = File.join(dir, "agent_artifact.txt")
      File.write(untracked, "agent-created\n")
      assert File.exist?(untracked), "fixture set up correctly"

      ops = Hive::GitOps.new(dir)
      assert ops.reset_hard_orig_head, "reset_hard_orig_head returns true on success"
      refute File.exist?(untracked),
             "untracked agent-created file must be removed by reset_hard_orig_head + git clean -fd"
    end
  end
end
