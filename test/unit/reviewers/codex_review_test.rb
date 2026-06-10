require "test_helper"
require "hive/reviewers"
require "hive/agent_profiles"

class ReviewersCodexReviewTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../../fixtures/fake-codex", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CODEX_BIN"]
    ENV["HIVE_CODEX_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_CODEX_BIN"] = @prev_bin
    %w[HIVE_FAKE_CODEX_STDOUT HIVE_FAKE_CODEX_EXIT HIVE_FAKE_CODEX_ARGV_LOG
       HIVE_FAKE_CODEX_HANG HIVE_FAKE_CODEX_VERSION].each { |k| ENV.delete(k) }
    Hive::AgentProfile.reset_version_cache!
  end

  def make_ctx(dir)
    Hive::Reviewers::Context.new(
      worktree_path: dir,
      task_folder: File.join(dir, ".hive-state", "stages", "6-review", "test"),
      default_branch: "main",
      pass: 1
    )
  end

  def make_spec(overrides = {})
    {
      "name" => "codex-native-review",
      "kind" => "codex_review",
      "agent" => "codex",
      "output_basename" => "codex-native-review",
      "prompt_template" => "reviewer_codex_native_review.md.erb",
      "timeout_sec" => 5
    }.merge(overrides)
  end

  def build_reviewer(dir, overrides = {})
    ctx = make_ctx(dir)
    FileUtils.mkdir_p(ctx.task_folder)
    Hive::Reviewers::CodexReview.new(make_spec(overrides), ctx)
  end

  # --- argv construction -------------------------------------------------

  def test_builds_codex_review_argv_with_title_and_prompt
    with_tmp_dir do |dir|
      log = File.join(dir, "argv.log")
      ENV["HIVE_FAKE_CODEX_ARGV_LOG"] = log
      reviewer = build_reviewer(dir)

      result = reviewer.run!

      assert result.ok?, "expected :ok, got #{result.status} (#{result.error_message})"
      raw = File.read(log)
      # Leading positional args are logged one-per-line; the trailing
      # prompt arg is multi-line, so assert against the raw log.
      args = raw.lines.grep(/^arg=/).map { |l| l.sub(/^arg=/, "").chomp }
      assert_equal "review", args[0], "first codex arg must be the review subcommand"
      title_idx = args.index("--title")
      refute_nil title_idx, "argv must carry --title"
      assert_includes args[title_idx + 1], "pass 1", "title carries the pass number"
      # codex rejects --base alongside a custom prompt, so we never pass --base.
      refute_includes args, "--base", "must NOT pass --base (mutually exclusive with custom prompt)"
      assert_includes raw, "git diff main...HEAD",
                      "prompt must scope the review to the base-branch diff"
      assert_includes raw, "## High", "prompt must coerce the GFM findings format"
    end
  end

  def test_runs_codex_in_worktree_cwd
    with_tmp_dir do |dir|
      log = File.join(dir, "argv.log")
      ENV["HIVE_FAKE_CODEX_ARGV_LOG"] = log
      reviewer = build_reviewer(dir)

      reviewer.run!

      cwd_line = File.readlines(log).grep(/^cwd=/).first.to_s.chomp.sub(/^cwd=/, "")
      assert_equal File.realpath(dir), File.realpath(cwd_line),
                   "codex review must run with cwd = the worktree path"
    end
  end

  # --- stdout -> findings file ------------------------------------------

  def test_captures_stdout_into_findings_file
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)

      result = reviewer.run!

      assert result.ok?
      assert_equal reviewer.output_path, result.output_path
      assert File.exist?(reviewer.output_path), "findings file must be written"
      body = File.read(reviewer.output_path)
      assert body.start_with?("## High"), "banner noise must be trimmed to the first severity header"
      assert_includes body, "uses subtraction instead of addition"
      assert_includes body, "## Nit"
      refute_includes body, "OpenAI Codex", "codex banner must not leak into the findings file"
    end
  end

  def test_accepts_output_with_only_some_severity_headers
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "## Medium\n- [ ] thing: reason\n"
      reviewer = build_reviewer(dir)

      result = reviewer.run!

      assert result.ok?, "a single severity header is enough to count as valid findings"
      assert_equal "## Medium\n- [ ] thing: reason\n", File.read(reviewer.output_path)
    end
  end

  # --- malformed / empty stdout -> error, no findings file --------------

  def test_malformed_stdout_yields_error_and_no_findings_file
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "OpenAI Codex v0.139.0\nReview was interrupted.\n"
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?, "missing High/Medium/Nit headers must fail the reviewer"
      assert_match(/missing High\/Medium\/Nit/, result.error_message)
      refute File.exist?(reviewer.output_path),
             "a malformed findings file must not be left behind for triage"
    end
  end

  def test_empty_stdout_yields_error
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = ""
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?
      refute File.exist?(reviewer.output_path)
    end
  end

  def test_nonzero_exit_yields_error
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_EXIT"] = "1"
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "ERROR: You've hit your usage limit.\n"
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?
      assert_match(/exited with status=1/, result.error_message)
      refute File.exist?(reviewer.output_path)
    end
  end

  def test_missing_binary_yields_error
    with_tmp_dir do |dir|
      ENV["HIVE_CODEX_BIN"] = File.join(dir, "does-not-exist-codex")
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?
      assert_match(/preflight failed|not runnable/, result.error_message)
      refute File.exist?(reviewer.output_path)
    end
  end

  # --- retry / multi-attempt message ------------------------------------

  def test_retries_then_succeeds_and_appends_no_attempt_suffix_on_success
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir, "max_attempts" => 2)
      # Patch backoff to avoid real sleeps.
      def reviewer.backoff(_seconds) = nil

      result = reviewer.run!

      assert result.ok?
    end
  end

  def test_error_message_includes_attempt_count_when_retry_enabled
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "no headers here\n"
      reviewer = build_reviewer(dir, "max_attempts" => 2)
      # Real backoff path, but zero-duration so sleep(0) returns instantly.
      def reviewer.backoff_seconds_for(_attempt) = 0

      result = reviewer.run!

      assert result.error?
      assert_match(/after 2 attempt\(s\)/, result.error_message)
    end
  end

  def test_retry_with_future_deadline_clamps_backoff_then_retries
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "no headers here\n"
      reviewer = build_reviewer(dir, "max_attempts" => 2)
      def reviewer.backoff_seconds_for(_attempt) = 0

      # A far-future deadline leaves ample budget, so the loop takes the
      # clamp branch (`[backoff, remaining].min`) and still retries.
      future = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3600
      result = reviewer.run!(deadline: future)

      assert result.error?
      assert_match(/after 2 attempt\(s\)/, result.error_message)
    end
  end

  def test_invalid_max_attempts_falls_back_to_default_with_warning
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir, "max_attempts" => "two")
      def reviewer.backoff(_seconds) = nil

      out, err = capture_subprocess_io do
        @result = reviewer.run!
      end
      _ = out

      assert @result.ok?
      assert_match(/invalid max_attempts/, err)
    end
  end

  # --- deadline handling -------------------------------------------------

  def test_deadline_already_passed_yields_error_without_spawning
    with_tmp_dir do |dir|
      log = File.join(dir, "argv.log")
      ENV["HIVE_FAKE_CODEX_ARGV_LOG"] = log
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      past = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10
      result = reviewer.run!(deadline: past)

      assert result.error?
      assert_match(/deadline reached/, result.error_message)
      refute File.exist?(log), "no codex spawn when the deadline is already in the past"
    end
  end

  def test_future_deadline_allows_spawn
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)

      future = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3600
      result = reviewer.run!(deadline: future)

      assert result.ok?
    end
  end

  def test_deadline_exhausted_between_failed_attempts_stops_retry
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_STDOUT"] = "no headers\n"
      reviewer = build_reviewer(dir, "max_attempts" => 3)
      # deadline_remaining is consulted twice per attempt: once by
      # effective_timeout (needs a positive budget so the spawn proceeds),
      # then once in the retry backoff check. Feed a large value first, then
      # a non-positive one so the loop breaks on `remaining <= 0` rather than
      # exhausting all 3 attempts.
      slack = [ 9999.0, 0.0 ]
      reviewer.define_singleton_method(:deadline_remaining) do |_deadline|
        slack.shift || -1
      end
      def reviewer.backoff(_seconds) = nil

      future = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3600
      result = reviewer.run!(deadline: future)

      assert result.error?
      # Broke after the first failed attempt (not all 3).
      assert_match(/after 1 attempt\(s\)/, result.error_message)
    end
  end

  # --- timeout -----------------------------------------------------------

  def test_timeout_kills_the_subprocess_and_errors
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_HANG"] = "30"
      reviewer = build_reviewer(dir, "timeout_sec" => 1, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?
      assert_match(/timed out after 1s/, result.error_message)
      refute File.exist?(reviewer.output_path)
    end
  end

  def test_terminate_is_quiet_when_process_already_gone
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)
      # Spawn a trivial child, reap it, then ask terminate to act on the
      # now-dead pid. Both the kill (ESRCH) and the reap (ECHILD) must be
      # swallowed without raising.
      pid = Process.spawn("true", pgroup: true)
      Process.wait(pid)

      assert_nil reviewer.send(:terminate, pid),
                 "terminate must be a no-op for an already-reaped pid"
      assert_nil reviewer.send(:reap, pid),
                 "reap must swallow ECHILD for an already-reaped pid"
    end
  end

  # --- version gate ------------------------------------------------------

  def test_below_min_version_yields_preflight_error
    with_tmp_dir do |dir|
      ENV["HIVE_FAKE_CODEX_VERSION"] = "0.1.0"
      reviewer = build_reviewer(dir, "max_attempts" => 1)

      result = reviewer.run!

      assert result.error?
      assert_match(/preflight failed/, result.error_message)
    end
  end

  # --- prompt rendering --------------------------------------------------

  def test_prompt_template_renders_base_branch_and_format_contract
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)
      File.write(
        File.join(reviewer.ctx.task_folder, "plan.md"),
        "# Plan\n\n## Goals\n- G1. Keep add() additive.\n"
      )
      prompt = reviewer.send(:render_prompt)

      assert_includes prompt, "git diff main...HEAD"
      assert_includes prompt, "## High"
      assert_includes prompt, "## Medium"
      assert_includes prompt, "## Nit"
      assert_includes prompt, "No findings."
      assert_match(/Plan context \(authoritative on scope\)/, prompt,
                   "native-review template must embed the plan-context section")
      assert_includes prompt, "G1. Keep add() additive.",
                      "plan.md content must be inlined into the prompt"
    end
  end

  def test_prompt_template_falls_back_to_absent_note_when_plan_missing
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)
      prompt = reviewer.send(:render_prompt)

      assert_match(/no plan\.md found/, prompt)
    end
  end

  def test_delete_output_reraises_on_non_enoent_system_call_error
    with_tmp_dir do |dir|
      reviewer = build_reviewer(dir)
      # Point output_path at a directory; File.delete raises EISDIR/EPERM
      # (a non-ENOENT SystemCallError) which must surface as a named
      # Hive::Error rather than being swallowed like a missing file.
      a_dir = File.join(dir, "a-directory")
      FileUtils.mkdir_p(a_dir)
      reviewer.define_singleton_method(:output_path) { a_dir }

      err = assert_raises(Hive::Error) { reviewer.send(:delete_output!) }
      assert_match(/failed to clear partial output_path/, err.message)
    end
  end

  # --- dispatch ----------------------------------------------------------

  def test_dispatch_selects_codex_review_for_codex_review_kind
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      adapter = Hive::Reviewers.dispatch(make_spec, ctx)
      assert_instance_of Hive::Reviewers::CodexReview, adapter
    end
  end

  def test_dispatch_defaults_to_agent_when_kind_absent
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      spec = make_spec.tap { |s| s.delete("kind") }.merge("skill" => "ce-code-review")
      adapter = Hive::Reviewers.dispatch(spec, ctx)
      assert_instance_of Hive::Reviewers::Agent, adapter
    end
  end

  def test_dispatch_rejects_unknown_kind
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      err = assert_raises(Hive::Reviewers::UnknownKindError) do
        Hive::Reviewers.dispatch(make_spec("kind" => "bogus"), ctx)
      end
      assert_match(/codex_review/, err.message)
    end
  end
end
