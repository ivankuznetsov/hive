require "test_helper"
require "hive/commands/init"
require "hive/commands/run"
require "hive/stages/finalize"
require "hive/task"

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
      HIVE_FAKE_GH_READY_STDERR HIVE_FAKE_GH_EDIT_EXIT HIVE_FAKE_GH_EDIT_STDERR
      HIVE_FAKE_GH_VIEW_EXIT HIVE_FAKE_GH_AUTH_EXIT
    ].each { |k| ENV.delete(k) }
  end

  def gh_argv_log
    path = File.join(@gh_log_dir, "fake-gh-argv.log")
    File.exist?(path) ? File.read(path) : ""
  end

  def with_stubbed_singleton_method(object, name, replacement)
    original = object.method(name)
    object.define_singleton_method(name, replacement)
    yield
  ensure
    object.define_singleton_method(name) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end

  def setup_finalize_task(dir)
    capture_io { Hive::Commands::Init.new(dir).call }
    set_project_claude_mode(dir, "headless")
    slug = "fix-bug-260424-aaaa"
    task_dir = File.join(dir, ".hive-state", "stages", "8-finalize", slug)
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

  # After the `stages.ensure_clean_on_exit` plan landed, the legacy
  # `dirty_worktree` marker is replaced by `ensure_clean_on_exit_failed`
  # for the scope-violating residue case. The Telegram bot routes that
  # reason to manual-only so an operator gets the "open it on a laptop"
  # reply instead of a retry loop. `dirty` at the worktree root matches
  # no allowed_paths in the default scope-check config, so CleanExit
  # returns :scope_violation and finalize marks :error.
  def test_finalize_dirty_worktree_out_of_scope_marks_clean_exit_failure
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path, pr_md = setup_finalize_task(dir)
        File.write(File.join(worktree_path, "dirty"), "x")

        _out, _err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }

        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        marker = Hive::Markers.current(pr_md)
        assert_equal :error, marker.name
        assert_equal "ensure_clean_on_exit_failed", marker.attrs["reason"],
                     "scope-violating residue must surface via the new ensure_clean_on_exit_failed reason"
        assert_includes marker.attrs["residue_paths"].to_s, "dirty"
      end
    end
  end

  # Defense-in-depth backstop: in-scope residue at finalize entry must
  # auto-commit as `chore(8-finalize): commit residual worktree changes`
  # (with structured Hive-Auto-Commit trailers) and let finalize push,
  # rather than abort. This is the path that self-heals an in-flight
  # feature whose stage hook didn't yet exist.
  def test_finalize_dirty_worktree_in_scope_auto_commits_and_pushes
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path, pr_md = setup_finalize_task(dir)
        # `lib/foo.rb` matches the default review.fix.auto_commit
        # scope_check allowlist (`lib/**`).
        FileUtils.mkdir_p(File.join(worktree_path, "lib"))
        File.write(File.join(worktree_path, "lib", "foo.rb"), "module Foo; end\n")

        capture_io { Hive::Commands::Run.new(task_dir).call }

        head_subject, _err, head_status = Open3.capture3(
          "git", "-C", worktree_path, "log", "-1", "--pretty=%s"
        )
        head_body, _err2, body_status = Open3.capture3(
          "git", "-C", worktree_path, "log", "-1", "--pretty=%B"
        )
        assert head_status.success?
        assert body_status.success?
        assert_equal "chore(8-finalize): commit residual worktree changes",
                     head_subject.strip,
                     "finalize backstop must commit residue with the canonical chore() subject"
        assert_match(/Hive-Auto-Commit: residue/, head_body)
        assert_match(/Hive-Auto-Commit-Reason: finalize_entry_backstop/, head_body)
        assert_match(/Hive-Stage: 8-finalize/, head_body)

        # And the marker is NOT in error — finalize proceeded past
        # verify_state! into the agent path.
        marker = Hive::Markers.current(pr_md)
        refute_equal :error, marker.name,
                     "in-scope residue must not produce a finalize error marker"

        # A residue log was dropped under the task log dir.
        task = Hive::Task.new(task_dir)
        residue_logs = Dir[File.join(task.log_dir, "finalize-residue-committed-*.log")]
        refute_empty residue_logs, "finalize backstop must record the residue commit to a log file"
      end
    end
  end

  def test_finalize_requires_pr_md
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, _pr_md = setup_finalize_task(dir)
        FileUtils.rm_f(File.join(task_dir, "pr.md"))
        ENV["HIVE_FAKE_GH_AUTH_EXIT"] = "1"

        _out, err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }

        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        assert_includes err, "finalize entered without 5-open-pr"
        marker = Hive::Markers.current(File.join(task_dir, "pr.md"))
        assert_equal :error, marker.name
        assert_equal "missing_pr_md", marker.attrs["reason"]
        assert_equal "", gh_argv_log,
                     "missing pr.md must short-circuit before gh auth, push, or agent spawn"
      end
    end
  end

  def test_finalize_requires_pr_url
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, pr_md = setup_finalize_task(dir)
        File.write(pr_md, <<~MD)
          ---
          pr_number: 9
          ---

          ## Summary
          draft

          <!-- COMPLETE is_draft=true -->
        MD
        ENV["HIVE_FAKE_GH_AUTH_EXIT"] = "1"

        _out, err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }

        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        assert_includes err, "finalize entered with pr.md missing pr_url"
        marker = Hive::Markers.current(pr_md)
        assert_equal :error, marker.name
        assert_equal "missing_pr_url", marker.attrs["reason"]
        assert_equal "", gh_argv_log,
                     "missing pr_url must short-circuit before gh auth, push, or agent spawn"
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
        # The argv log carries `arg=<value>` one line per gh argv; the
        # redact payload's `--body` argument is the literal placeholder.
        # Without this assertion, a regression that passed the
        # secret-laden agent body to `gh pr edit --body ...` (instead of
        # the placeholder) would pass: the URL + `arg=edit` pair only
        # proves edit was *called*, not that the body was redacted.
        assert_match(/arg=\[redacted: hive detected a credential pattern\]/, log,
                     "gh pr edit --body must carry the redacted placeholder, not the secret-laden agent body")
        refute_match(/arg=.*sk-ant-aaaaaa/, log,
                     "the agent-supplied secret must NOT appear in any gh argv")
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

  def test_finalize_agent_tampering_sets_error_marker
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, pr_md = setup_finalize_task(dir)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(task_dir, "plan.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "tampered plan\n"

        _out, _err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }

        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        marker = Hive::Markers.current(pr_md)
        assert_equal :error, marker.name
        assert_equal "finalize_tampered", marker.attrs["reason"]
        assert_equal "plan.md", marker.attrs["files"]
        refute File.exist?(File.join(task_dir, "summary.md"))
      end
    end
  end

  def test_finalize_secret_scan_fetch_failure_sets_error_before_ready
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
          api_key sk-ant-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

          <!-- COMPLETE pr_url=https://example.com/pr/9 is_draft=false -->
        MD
        ENV["HIVE_FAKE_GH_VIEW_EXIT"] = "1"

        _out, _err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }

        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        marker = Hive::Markers.current(pr_md)
        assert_equal :error, marker.name
        assert_equal "secret_scan_fetch_failed", marker.attrs["reason"]
        refute_empty marker.attrs["patterns"].to_s
        refute_match(/arg=ready\n/, gh_argv_log)
      end
    end
  end

  def test_finalize_worktree_pointer_exit_paths
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path, _pr_md = setup_finalize_task(dir)
        task = Hive::Task.new(task_dir)
        FileUtils.rm_f(File.join(task_dir, "worktree.yml"))

        _out, err, status = with_captured_exit do
          Hive::Stages::Finalize.worktree_pointer_or_exit(task)
        end

        assert_equal 1, status
        assert_match(/no worktree pointer/, err)

        File.write(File.join(task_dir, "worktree.yml"), { "path" => worktree_path }.to_yaml)
        FileUtils.rm_rf(worktree_path)

        _out, err, status = with_captured_exit do
          Hive::Stages::Finalize.worktree_pointer_or_exit(task)
        end

        assert_equal 1, status
        assert_match(/worktree pointer .* no longer exists/, err)
      end
    end
  end

  def test_finalize_verify_state_records_git_status_failure
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, pr_md = setup_finalize_task(dir)
        task = Hive::Task.new(task_dir)
        missing_worktree = File.join(dir, "missing-worktree")

        result = Hive::Stages::Finalize.verify_state!(task, missing_worktree, "missing", {})

        assert_equal({ commit: "finalize_git_status_failed", status: :error }, result)
        marker = Hive::Markers.current(pr_md)
        assert_equal :error, marker.name
        assert_equal "git_status_failed", marker.attrs["reason"]
      end
    end
  end

  def test_finalize_complete_marker_validation_error_paths
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, pr_md = setup_finalize_task(dir)
        task = Hive::Task.new(task_dir)
        expected_url = "https://example.com/pr/9"

        File.write(pr_md, "---\npr_url: https://example.com/pr/wrong\n---\n\nbody\n")
        Hive::Markers.set(pr_md, :complete, pr_url: expected_url, is_draft: "false")
        result = Hive::Stages::Finalize.validate_complete_marker(
          task, Hive::Markers.current(pr_md), expected_url
        )
        assert_equal({ commit: "finalize_pr_url_tampered", status: :error }, result)
        assert_equal "https://example.com/pr/wrong", Hive::Markers.current(pr_md).attrs["actual_pr_url"]

        File.write(pr_md, "---\npr_url: #{expected_url}\n---\n\nbody\n")
        Hive::Markers.set(pr_md, :complete, pr_url: "https://example.com/pr/wrong", is_draft: "false")
        result = Hive::Stages::Finalize.validate_complete_marker(
          task, Hive::Markers.current(pr_md), expected_url
        )
        assert_equal({ commit: "finalize_pr_url_tampered", status: :error }, result)
        assert_equal "https://example.com/pr/wrong", Hive::Markers.current(pr_md).attrs["actual_pr_url"]

        File.write(pr_md, "---\npr_url: #{expected_url}\n---\n\nbody\n")
        Hive::Markers.set(pr_md, :complete, pr_url: expected_url, is_draft: "true")
        result = Hive::Stages::Finalize.validate_complete_marker(
          task, Hive::Markers.current(pr_md), expected_url
        )
        assert_equal({ commit: "finalize_marker_not_ready", status: :error }, result)
        assert_equal "finalize_marker_not_ready", Hive::Markers.current(pr_md).attrs["reason"]
      end
    end
  end

  def test_finalize_mark_pr_ready_error_paths
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, pr_md = setup_finalize_task(dir)
        task = Hive::Task.new(task_dir)
        pr_url = "https://example.com/pr/9"
        ENV["HIVE_FAKE_GH_READY_EXIT"] = "1"
        ENV["HIVE_FAKE_GH_READY_STDERR"] = "Pull request is already ready for review"

        assert_nil Hive::Stages::Finalize.mark_pr_ready(task, pr_url, {})

        ENV["HIVE_FAKE_GH_READY_STDERR"] = "permission denied"
        result = Hive::Stages::Finalize.mark_pr_ready(task, pr_url, {})
        assert_equal({ commit: "finalize_pr_ready_failed", status: :error }, result)
        assert_equal "gh_pr_ready_failed", Hive::Markers.current(pr_md).attrs["reason"]
        assert_equal "permission denied", Hive::Markers.current(pr_md).attrs["detail"]

        with_stubbed_singleton_method(Hive::Gh, :capture3, lambda { |*_, **_kwargs|
          raise Hive::GhError, "network down"
        }) do
          result = Hive::Stages::Finalize.mark_pr_ready(task, pr_url, {})
          assert_equal({ commit: "finalize_pr_ready_failed", status: :error }, result)
          assert_equal "network down", Hive::Markers.current(pr_md).attrs["detail"]
        end
      end
    end
  end

  def test_finalize_redact_pr_body_error_paths
    assert_equal :skipped, Hive::Stages::Finalize.redact_pr_body!("", {})

    ENV["HIVE_FAKE_GH_EDIT_EXIT"] = "1"
    ENV["HIVE_FAKE_GH_EDIT_STDERR"] = "edit denied"
    result = nil
    _out, err = capture_io do
      result = Hive::Stages::Finalize.redact_pr_body!("https://example.com/pr/9", {})
    end
    assert_equal :failed, result
    assert_match(/failed to redact PR body/, err)
    assert_match(/edit denied/, err)

    with_stubbed_singleton_method(Hive::Gh, :capture3, lambda { |*_, **_kwargs|
      raise RuntimeError, "boom"
    }) do
      result = nil
      _out, err = capture_io do
        result = Hive::Stages::Finalize.redact_pr_body!("https://example.com/pr/9", {})
      end
      assert_equal :failed, result
      assert_match(/redact_pr_body raised RuntimeError: boom/, err)
    end
  end

  def test_finalize_summary_helper_fallbacks
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, _pr_md = setup_finalize_task(dir)
        task = Hive::Task.new(task_dir)

        assert_equal "Final PR description refreshed.",
                     Hive::Stages::Finalize.extract_summary(File.join(task_dir, "missing-pr.md"))

        no_summary = File.join(task_dir, "no-summary.md")
        File.write(no_summary, "## Details\nNo summary section\n")
        assert_equal "Final PR description refreshed.", Hive::Stages::Finalize.extract_summary(no_summary)

        FileUtils.rm_rf(task.reviews_dir)
        assert_equal "(no reviews/ directory found)", Hive::Stages::Finalize.build_reviews_summary(task)
        assert_equal "", Hive::Stages::Finalize.read_optional(task, "missing.md")
      end
    end
  end

  def test_finalize_review_and_escalation_helper_edge_paths
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, _pr_md = setup_finalize_task(dir)
        task = Hive::Task.new(task_dir)
        File.write(File.join(task.reviews_dir, "notes-extra.md"), "not a numbered review\n")

        assert_match(/Review passes: 1\b/, Hive::Stages::Finalize.review_summary(task))

        missing_escalations = File.join(task.reviews_dir, "escalations-01.md")
        with_stubbed_singleton_method(Dir, :[], lambda { |pattern|
          pattern.include?("escalations-*.md") ? [ missing_escalations ] : []
        }) do
          result = nil
          _out, err = capture_io { result = Hive::Stages::Finalize.open_escalations(task) }
          assert_equal "", result
          assert_match(/disappeared mid-read/, err)
        end
      end
    end
  end
end
