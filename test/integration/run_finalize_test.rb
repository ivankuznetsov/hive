require "test_helper"
require "hive/commands/init"
require "hive/commands/run"

class RunFinalizeTest < Minitest::Test
  include HiveTestHelper

  def setup
    @prev_path = ENV["PATH"]
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_CLAUDE_FIXTURE
    @gh_dir = Dir.mktmpdir("fake-gh-bin")
    File.symlink(FAKE_GH_FIXTURE, File.join(@gh_dir, "gh"))
    ENV["PATH"] = "#{@gh_dir}:#{@prev_path}"
    @gh_log_dir = Dir.mktmpdir("fake-gh-log")
    ENV["HIVE_FAKE_GH_LOG_DIR"] = @gh_log_dir
  end

  def teardown
    ENV["PATH"] = @prev_path
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    FileUtils.rm_rf(@gh_dir) if @gh_dir
    FileUtils.rm_rf(@gh_log_dir) if @gh_log_dir
    Array(@worktree_paths).each { |p| FileUtils.rm_rf(p) }
    %w[
      HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
      HIVE_FAKE_GH_LOG_DIR HIVE_FAKE_GH_PR_BODY HIVE_FAKE_GH_READY_EXIT
      HIVE_FAKE_GH_VIEW_EXIT HIVE_FAKE_GH_AUTH_EXIT
    ].each { |k| ENV.delete(k) }
  end

  def gh_argv_log
    path = File.join(@gh_log_dir, "fake-gh-argv.log")
    File.exist?(path) ? File.read(path) : ""
  end

  def setup_finalize_task(dir)
    capture_io { Hive::Commands::Init.new(dir).call }
    slug = "fix-bug-260424-aaaa"
    task_dir = File.join(dir, ".hive-state", "stages", "7-finalize", slug)
    FileUtils.mkdir_p(task_dir)
    File.write(File.join(task_dir, "plan.md"), "plan content")
    FileUtils.mkdir_p(File.join(task_dir, "reviews"))
    File.write(File.join(task_dir, "reviews", "codex-01.md"), "- [x] fixed\n")
    worktree_path = Dir.mktmpdir("wt-#{slug}-")
    @worktree_paths ||= []
    @worktree_paths << worktree_path
    run!("git", "-C", worktree_path, "init", "-b", slug, "--quiet")
    run!("git", "-C", worktree_path, "config", "user.email", "t@t")
    run!("git", "-C", worktree_path, "config", "user.name", "t")
    run!("git", "-C", worktree_path, "config", "commit.gpgsign", "false")
    File.write(File.join(worktree_path, "f"), "x")
    run!("git", "-C", worktree_path, "add", ".")
    run!("git", "-C", worktree_path, "commit", "-m", "wt", "--quiet")
    bare = "#{worktree_path}-remote.git"
    @worktree_paths << bare
    run!("git", "init", "--bare", bare, "--quiet")
    run!("git", "-C", worktree_path, "remote", "add", "origin", bare)
    run!("git", "-C", worktree_path, "push", "-u", "origin", slug, "--quiet")
    File.write(File.join(task_dir, "worktree.yml"),
               { "path" => worktree_path, "branch" => slug }.to_yaml)
    pr_md = File.join(task_dir, "pr.md")
    File.write(pr_md, <<~MD)
      ---
      pr_url: https://example.com/pr/9
      pr_number: 9
      ---

      ## Summary
      draft

      <!-- COMPLETE pr_url=https://example.com/pr/9 is_draft=true -->
    MD
    [ task_dir, worktree_path, pr_md ]
  end

  def test_finalize_writes_summary_after_agent_completion
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, pr_md = setup_finalize_task(dir)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = pr_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = <<~MD
          ---
          pr_url: https://example.com/pr/9
          pr_number: 9
          ---

          ## Summary
          final

          <!-- COMPLETE pr_url=https://example.com/pr/9 is_draft=false -->
        MD

        capture_io { Hive::Commands::Run.new(task_dir).call }

        marker = Hive::Markers.current(pr_md)
        assert_equal :complete, marker.name
        # Tightened (round-1 finding): assert the marker carries
        # `is_draft=false` so a regression accepting the open-pr
        # `is_draft=true` marker as terminal would fail.
        assert_equal "false", marker.attrs["is_draft"],
                     "finalize must require is_draft=false marker, not the open-pr is_draft=true"
        assert File.exist?(File.join(task_dir, "summary.md"))
        assert_includes File.read(File.join(task_dir, "summary.md")), "https://example.com/pr/9"

        # AC4: runner OWNS `gh pr ready`. Argv log must show it was
        # invoked with the PR URL. A regression that drops this call
        # would silently leave the PR in draft state after finalize.
        assert_match(/arg=ready\n.*arg=https:\/\/example\.com\/pr\/9/m, gh_argv_log,
                     "finalize runner must invoke `gh pr ready <pr_url>`")
      end
    end
  end

  def test_finalize_dirty_worktree_sets_error
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path, pr_md = setup_finalize_task(dir)
        File.write(File.join(worktree_path, "dirty"), "x")

        _out, _err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }

        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        marker = Hive::Markers.current(pr_md)
        assert_equal :error, marker.name
        assert_equal "dirty_worktree", marker.attrs["reason"]
      end
    end
  end

  def test_finalize_requires_pr_md
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, _pr_md = setup_finalize_task(dir)
        FileUtils.rm_f(File.join(task_dir, "pr.md"))

        _out, err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }

        assert_equal 1, status
        assert_includes err, "finalize entered without 5-open-pr"
      end
    end
  end

  # R4 (secret-in-pr-body in Finalize): the deleted test in run_pr_test.rb
  # had `test_pr_runner_blocks_when_pr_body_contains_anthropic_key`. This
  # is the equivalent for finalize: when the agent-refreshed body
  # contains a credential pattern, the runner MUST land
  # ERROR reason=secret_in_pr_body BEFORE invoking `gh pr ready`,
  # and MUST redact the PR body. A regression in SecretPatterns.scan
  # or the runner's gate would silently let the secret reach a public
  # ready PR.
  def test_finalize_secret_in_pr_body_blocks_ready
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, pr_md = setup_finalize_task(dir)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = pr_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = <<~MD
          ---
          pr_url: https://example.com/pr/9
          pr_number: 9
          ---

          ## Summary
          api_key sk-ant-#{"a" * 30}

          <!-- COMPLETE pr_url=https://example.com/pr/9 is_draft=false -->
        MD

        _out, _err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }
        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        marker = Hive::Markers.current(pr_md)
        assert_equal :error, marker.name
        assert_equal "secret_in_pr_body", marker.attrs["reason"]
        # gh pr ready must NOT have been invoked; gh pr edit (the
        # redact) must have been invoked.
        log = gh_argv_log
        refute_match(/arg=ready\n/, log, "ready must NOT fire when secret detected")
        assert_match(/arg=edit\n.*arg=https:\/\/example\.com\/pr\/9/m, log,
                     "finalize must redact the secret-bearing PR body")
        refute File.exist?(File.join(task_dir, "summary.md")),
               "summary.md must not be written when secret blocks finalize"
      end
    end
  end

  # plan U6 idempotency: a second `hive run` on a task whose summary.md
  # already exists must short-circuit (no agent spawn, no `gh pr ready`).
  def test_finalize_already_complete_short_circuits
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, pr_md = setup_finalize_task(dir)
        File.write(File.join(task_dir, "summary.md"), "previously written summary\n")
        # Re-mark pr.md as already-complete so warn includes the URL.
        Hive::Markers.set(pr_md, :complete, pr_url: "https://example.com/pr/9", is_draft: "false")

        _out, err = capture_io { Hive::Commands::Run.new(task_dir).call }
        assert_match(/already complete/, err)
        # gh pr ready must NOT fire on the idempotent path — argv log
        # may not exist at all if no gh call was issued.
        refute_match(/arg=ready\n/, gh_argv_log,
                     "idempotent already-complete path must NOT invoke gh pr ready")
      end
    end
  end

  # plan U6 unpushed-commits: when push fails persistently in
  # verify_state!, finalize must land ERROR reason=unpushed_commits
  # instead of an uncaught exit. Today push_branch! exits 1 on
  # failure — the new push_branch (non-bang) lets finalize record the
  # marker.
  def test_finalize_unpushed_commits_marker
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path, pr_md = setup_finalize_task(dir)
        # Add an unpushed commit on top, then break the remote to force
        # push failure. `git remote remove origin` strips the upstream
        # so the helper's push attempt fails.
        File.write(File.join(worktree_path, "extra"), "x")
        run!("git", "-C", worktree_path, "add", ".")
        run!("git", "-C", worktree_path, "commit", "-m", "extra", "--quiet")
        run!("git", "-C", worktree_path, "remote", "remove", "origin")

        _out, _err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }
        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status,
                     "persistent push failure must surface as a TASK_IN_ERROR exit (marker, not raw exit 1)"
        marker = Hive::Markers.current(pr_md)
        assert_equal :error, marker.name
        assert_equal "unpushed_commits", marker.attrs["reason"]
      end
    end
  end

  # plan U6 review_summary content: passes count + bias surface in
  # summary.md so the operator sees them without grepping reviews/.
  def test_finalize_summary_includes_passes_and_bias_lines
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, pr_md = setup_finalize_task(dir)
        # Setup additional review artifacts: pass 02 file + triage doc.
        File.write(File.join(task_dir, "reviews", "codex-02.md"), "- [x] fix\n")
        File.write(File.join(task_dir, "reviews", "triage-02.md"),
                   "bias: courageous\n\n- [x] applied\n")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = pr_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = <<~MD
          ---
          pr_url: https://example.com/pr/9
          pr_number: 9
          ---

          ## Summary
          final

          <!-- COMPLETE pr_url=https://example.com/pr/9 is_draft=false -->
        MD

        capture_io { Hive::Commands::Run.new(task_dir).call }

        summary = File.read(File.join(task_dir, "summary.md"))
        assert_match(/Review passes: 2\b/, summary,
                     "summary must show max pass derived from filenames")
        assert_match(/Triage bias: courageous\b/, summary,
                     "summary must surface triage bias from triage-NN.md")
      end
    end
  end
end
