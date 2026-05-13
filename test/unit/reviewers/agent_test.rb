require "test_helper"
require "hive/reviewers"
require "hive/agent_profiles"

class ReviewersAgentTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
       HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
       HIVE_FAKE_CLAUDE_LOG_DIR].each { |k| ENV.delete(k) }
    Hive::AgentProfile.reset_version_cache!
  end

  def make_ctx(dir)
    Hive::Reviewers::Context.new(
      worktree_path: dir,
      task_folder: File.join(dir, ".hive-state", "stages", "5-review", "test"),
      default_branch: "main",
      pass: 1
    )
  end

  def make_spec(overrides = {})
    {
      "name" => "claude-ce-code-review",
      "kind" => "agent",
      "agent" => "claude",
      "skill" => "ce-code-review",
      "output_basename" => "claude-ce-code-review",
      "prompt_template" => "reviewer_claude_ce_code_review.md.erb",
      "budget_usd" => 50,
      "timeout_sec" => 5
    }.merge(overrides)
  end

  def test_run_returns_ok_when_agent_writes_expected_output_file
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(ctx.task_folder)
      reviewer = Hive::Reviewers::Agent.new(make_spec, ctx)

      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = reviewer.output_path
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## High\n- [ ] finding: justification\n"

      result = reviewer.run!

      assert result.ok?, "expected :ok status, got #{result.status} (#{result.error_message})"
      assert_equal reviewer.output_path, result.output_path
      assert File.exist?(reviewer.output_path)
      assert_includes File.read(reviewer.output_path), "## High"
    end
  end

  def test_run_returns_error_when_agent_does_not_write_output_file
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(ctx.task_folder)
      reviewer = Hive::Reviewers::Agent.new(make_spec, ctx)
      # Fake claude exits 0 but doesn't write the expected file.

      result = reviewer.run!

      assert result.error?
      assert_match(/missing or empty/, result.error_message)
    end
  end

  def test_run_returns_error_when_agent_exits_nonzero
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(ctx.task_folder)
      reviewer = Hive::Reviewers::Agent.new(make_spec, ctx)
      ENV["HIVE_FAKE_CLAUDE_EXIT"] = "2"

      result = reviewer.run!

      assert result.error?
      assert_match(/exit_code=2/, result.error_message)
    end
  end

  def test_orchestrator_marker_is_not_clobbered_by_reviewer_spawn
    # Crucial regression: the 5-review runner sets REVIEW_WORKING phase=reviewers
    # before spawning each reviewer. The reviewer's spawn must not overwrite
    # that marker with :agent_working — that contract is gated by the
    # claude profile's :output_file_exists status_detection_mode (per U4).
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(ctx.task_folder)
      task_md = File.join(ctx.task_folder, "task.md")
      File.write(task_md, "## Implementation\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 -->\n")

      reviewer = Hive::Reviewers::Agent.new(make_spec, ctx)
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = reviewer.output_path
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## High\n- [ ] f: j\n"

      reviewer.run!

      content = File.read(task_md)
      assert_includes content, "<!-- REVIEW_WORKING phase=reviewers pass=1 -->",
                      "orchestrator-set REVIEW_WORKING must survive the reviewer spawn"
      refute_includes content, "AGENT_WORKING",
                      ":output_file_exists mode must not write task.state_file"
    end
  end

  # --- PE1: prompt_template path-escape is ConfigError -----------------

  def test_path_escape_in_reviewer_prompt_template_raises_config_error
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(ctx.task_folder)
      reviewer = Hive::Reviewers::Agent.new(
        make_spec("prompt_template" => "../../../etc/passwd"), ctx
      )

      assert_raises(Hive::ConfigError) { reviewer.run! }
    end
  end

  # --- U1 retry coverage -----------------------------------------------
  #
  # The retry loop is exercised by replacing Hive::Stages::Base.spawn_agent
  # with a singleton method on the module for the duration of the test so
  # we don't depend on minitest/mock (not in the Gemfile) and don't burn
  # fake-claude spawn time. backoff() is replaced on the adapter instance
  # so sleeps are recorded without burning wall time.

  def with_stubbed_adapter(dir, spec_overrides = {})
    ctx = make_ctx(dir)
    FileUtils.mkdir_p(ctx.task_folder)
    reviewer = Hive::Reviewers::Agent.new(make_spec(spec_overrides), ctx)
    sleeps = []
    reviewer.define_singleton_method(:backoff) { |sec| sleeps << sec }
    [ reviewer, sleeps ]
  end

  def with_spawn_stub(results)
    call_count = 0
    labels = []
    original = Hive::Stages::Base.method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_task, **kwargs|
      labels << kwargs[:log_label]
      result = results[call_count] || results.last
      call_count += 1
      result
    end
    begin
      yield(-> { call_count }, labels)
    ensure
      Hive::Stages::Base.singleton_class.send(:remove_method, :spawn_agent)
      Hive::Stages::Base.define_singleton_method(:spawn_agent, &original)
    end
  end

  def ok_result
    { status: :ok }
  end

  def error_result(message = "agent exited with status=:timeout")
    { status: :error, error_message: message }
  end

  def test_run_does_not_retry_when_first_attempt_succeeds
    with_tmp_dir do |dir|
      reviewer, sleeps = with_stubbed_adapter(dir)

      with_spawn_stub([ ok_result ]) do |count_fn, labels|
        result = reviewer.run!
        assert result.ok?
        assert_equal 1, count_fn.call,
                     "spawn_agent should be called exactly once on first-attempt success"
        assert_equal [ "review-claude-ce-code-review-pass01" ], labels,
                     "first attempt's log_label has no -retry suffix"
      end

      assert_empty sleeps, "no backoff should occur on first-attempt success"
    end
  end

  def test_run_retries_on_error_then_succeeds
    with_tmp_dir do |dir|
      reviewer, sleeps = with_stubbed_adapter(dir)

      with_spawn_stub([ error_result, ok_result ]) do |count_fn, labels|
        result = reviewer.run!
        assert result.ok?, "expected :ok after retry, got #{result.status}"
        assert_equal 2, count_fn.call
        assert_equal [
          "review-claude-ce-code-review-pass01",
          "review-claude-ce-code-review-pass01-retry1"
        ], labels
      end

      assert_equal [ 1 ], sleeps, "exactly one 1s sleep between attempt 1 and attempt 2"
    end
  end

  def test_run_exhausts_max_attempts_when_all_attempts_fail
    with_tmp_dir do |dir|
      reviewer, sleeps = with_stubbed_adapter(dir, "max_attempts" => 3)

      with_spawn_stub([ error_result, error_result, error_result ]) do |count_fn, _|
        result = reviewer.run!
        assert result.error?
        assert_match(/after 3 attempt\(s\)/, result.error_message,
                     "final error_message records the attempt count")
        assert_equal 3, count_fn.call
      end

      assert_equal [ 1, 2 ], sleeps,
                   "two backoff sleeps between three attempts: 1s, 2s"
    end
  end

  def test_run_backoff_cap_capped_at_eight_seconds
    with_tmp_dir do |dir|
      reviewer, sleeps = with_stubbed_adapter(dir, "max_attempts" => 6)

      with_spawn_stub([ error_result ] * 6) do |_, _|
        reviewer.run!
      end

      assert_equal [ 1, 2, 4, 8, 8 ], sleeps,
                   "backoff caps at 8s — five sleeps for six attempts, capped from 16 → 8"
    end
  end

  def test_run_max_attempts_one_short_circuits_no_sleep_no_retry_suffix
    with_tmp_dir do |dir|
      reviewer, sleeps = with_stubbed_adapter(dir, "max_attempts" => 1)

      with_spawn_stub([ error_result ]) do |count_fn, labels|
        result = reviewer.run!
        assert result.error?
        refute_match(/after \d+ attempt/, result.error_message,
                     "single-attempt configs preserve the original error_message shape")
        assert_equal 1, count_fn.call
        assert_equal [ "review-claude-ce-code-review-pass01" ], labels,
                     "max_attempts: 1 means no -retry suffix is ever generated"
      end

      assert_empty sleeps
    end
  end

  # pr-review-toolkit round-5 pr-test-analyzer #3 — deadline propagation behavior.
  def test_run_aborts_attempt_when_deadline_reached_before_spawn
    with_tmp_dir do |dir|
      reviewer, _ = with_stubbed_adapter(dir, "max_attempts" => 3)
      past_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10
      spawn_call_count = 0
      original = Hive::Stages::Base.method(:spawn_agent)
      Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_task, **_kwargs|
        spawn_call_count += 1
        { status: :ok }
      end
      begin
        result = reviewer.run!(deadline: past_deadline)
        assert result.error?
        assert_match(/deadline reached before attempt/, result.error_message)
        assert_equal 0, spawn_call_count, "spawn_agent must NOT be called when deadline is already past"
      ensure
        Hive::Stages::Base.singleton_class.send(:remove_method, :spawn_agent)
        Hive::Stages::Base.define_singleton_method(:spawn_agent, &original)
      end
    end
  end

  def test_run_clamps_spawn_timeout_to_deadline_remaining
    with_tmp_dir do |dir|
      reviewer, _ = with_stubbed_adapter(dir)
      # configured spec timeout_sec=5 (from make_spec); deadline allows
      # only 2 seconds of remaining budget. Effective timeout must be
      # clamped to ~2, not 5.
      tight_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      captured_timeouts = []
      original = Hive::Stages::Base.method(:spawn_agent)
      Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_task, **kwargs|
        captured_timeouts << kwargs[:timeout_sec]
        { status: :ok }
      end
      begin
        reviewer.run!(deadline: tight_deadline)
        assert_equal 1, captured_timeouts.size
        assert captured_timeouts.first <= 2,
               "effective timeout #{captured_timeouts.first} must be clamped to remaining budget (~2s)"
      ensure
        Hive::Stages::Base.singleton_class.send(:remove_method, :spawn_agent)
        Hive::Stages::Base.define_singleton_method(:spawn_agent, &original)
      end
    end
  end

  def test_run_uses_full_configured_timeout_when_no_deadline_supplied
    with_tmp_dir do |dir|
      reviewer, _ = with_stubbed_adapter(dir) # default spec timeout_sec=5
      captured_timeouts = []
      original = Hive::Stages::Base.method(:spawn_agent)
      Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_task, **kwargs|
        captured_timeouts << kwargs[:timeout_sec]
        { status: :ok }
      end
      begin
        reviewer.run! # no deadline kwarg
        assert_equal [ 5 ], captured_timeouts,
                     "without a deadline, the adapter uses the full configured timeout_sec"
      ensure
        Hive::Stages::Base.singleton_class.send(:remove_method, :spawn_agent)
        Hive::Stages::Base.define_singleton_method(:spawn_agent, &original)
      end
    end
  end

  def test_run_clears_output_path_on_every_retry_attempt
    # pr-review-toolkit round-5 pr-test-analyzer #9 — output_path must
    # be cleared before EACH attempt, not just the first. A regression
    # that hoists the clear out of the loop would let attempt 2's
    # stale file from attempt 1 satisfy the :output_file_exists check.
    with_tmp_dir do |dir|
      reviewer, _ = with_stubbed_adapter(dir, "max_attempts" => 3)
      FileUtils.mkdir_p(File.dirname(reviewer.output_path))

      observations = []
      original = Hive::Stages::Base.method(:spawn_agent)
      Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_task, **kwargs|
        observations << File.exist?(kwargs[:expected_output])
        # Simulate adapter writing a partial file before failing —
        # the next attempt's pre-spawn clear must wipe it.
        File.write(kwargs[:expected_output], "## High\n- [ ] partial\n")
        { status: :error, error_message: "agent exited with status=:timeout" }
      end
      begin
        reviewer.run!
        assert_equal 3, observations.size,
                     "expected 3 spawn attempts under max_attempts=3"
        assert observations.none?(true),
               "every attempt must see output_path absent at spawn-time, not just the first"
      ensure
        Hive::Stages::Base.singleton_class.send(:remove_method, :spawn_agent)
        Hive::Stages::Base.define_singleton_method(:spawn_agent, &original)
      end
    end
  end

  def test_run_falls_back_to_default_when_max_attempts_absent
    with_tmp_dir do |dir|
      reviewer, _ = with_stubbed_adapter(dir) # no max_attempts override

      with_spawn_stub([ error_result, error_result, error_result ]) do |count_fn, _|
        reviewer.run!
        assert_equal Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS,
                     count_fn.call,
                     "spec without max_attempts uses DEFAULT_REVIEWER_MAX_ATTEMPTS"
      end
    end
  end

  def test_run_clears_stale_output_path_before_each_attempt
    # ce-review P1 #3: a prior crashed attempt may have left a
    # non-empty file at output_path. spawn_agent's
    # :output_file_exists check only verifies file-exists + non-empty
    # + exit-0, so a retry that exits 0 (even with no real findings)
    # would be accepted on stale content. The adapter must clear
    # output_path before each spawn attempt.
    with_tmp_dir do |dir|
      reviewer, _ = with_stubbed_adapter(dir)
      FileUtils.mkdir_p(File.dirname(reviewer.output_path))
      File.write(reviewer.output_path, "STALE content from a prior crashed attempt\n")

      cleared_observations = []
      with_spawn_stub([ ok_result ]) do |count_fn, _labels|
        # Observe the file state inside the stub. spawn_agent is
        # replaced by the test stub, so we can inspect what's on disk
        # at the moment the stub runs.
        original = Hive::Stages::Base.method(:spawn_agent)
        Hive::Stages::Base.singleton_class.send(:remove_method, :spawn_agent)
        Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_task, **kwargs|
          cleared_observations << File.exist?(kwargs[:expected_output])
          { status: :ok }
        end
        begin
          reviewer.run!
        ensure
          Hive::Stages::Base.singleton_class.send(:remove_method, :spawn_agent)
          Hive::Stages::Base.define_singleton_method(:spawn_agent, &original)
        end
        _ = count_fn # silence unused-block-arg
      end

      refute_includes cleared_observations, true,
                      "stale output_path must be deleted BEFORE spawn_agent runs"
    end
  end

  def test_run_deletes_output_path_after_final_failure
    # ce-review P1 #3: even after the retry loop exhausts, a partial
    # file from the last attempt could be left at output_path. Triage's
    # discover_reviewer_files would then mistake it for real reviewer
    # output. Final failures must surface only through errors-NN.md.
    with_tmp_dir do |dir|
      reviewer, _ = with_stubbed_adapter(dir, "max_attempts" => 1)
      FileUtils.mkdir_p(File.dirname(reviewer.output_path))

      # Stub spawn_agent to "fail" but leak a partial output file —
      # simulating an agent that wrote a half-finished file then
      # exited nonzero.
      original = Hive::Stages::Base.method(:spawn_agent)
      Hive::Stages::Base.singleton_class.send(:remove_method, :spawn_agent)
      Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_task, **kwargs|
        File.write(kwargs[:expected_output], "## High\n- [ ] partial output before crash\n")
        { status: :error, error_message: "agent exited with status=:timeout" }
      end
      begin
        result = reviewer.run!
        assert result.error?
      ensure
        Hive::Stages::Base.singleton_class.send(:remove_method, :spawn_agent)
        Hive::Stages::Base.define_singleton_method(:spawn_agent, &original)
      end

      refute File.exist?(reviewer.output_path),
             "final-failure cleanup must delete output_path so triage doesn't see partial content"
    end
  end

  def test_run_recovers_from_non_integer_max_attempts_value
    # Defensive: if validate_reviewers! is bypassed (test fixtures,
    # ad-hoc cfg construction, future YAML path) a non-Integer value
    # could reach the adapter. Fall back to the default rather than
    # crashing inside spawn_agent.
    with_tmp_dir do |dir|
      reviewer, _ = with_stubbed_adapter(dir, "max_attempts" => "not-a-number")

      with_spawn_stub([ error_result ] * 5) do |count_fn, _|
        result = reviewer.run!
        assert result.error?
        assert_equal Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS,
                     count_fn.call,
                     "non-Integer max_attempts falls back to the default"
      end
    end
  end

  def test_argv_invokes_claude_with_expected_skill_in_prompt
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(ctx.task_folder)
      reviewer = Hive::Reviewers::Agent.new(make_spec, ctx)

      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = reviewer.output_path
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## High\n- [ ] f: j\n"

      reviewer.run!

      argv = File.read(File.join(log_dir, "fake-claude-argv.log"))
      # The rendered prompt is the last positional argv arg.
      assert_includes argv, "/ce-code-review", "prompt must invoke /ce-code-review skill"
      assert_includes argv, ctx.task_folder, "prompt must mention the task folder"
      assert_includes argv, "git diff main..HEAD", "prompt must invoke the diff against the default branch"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end
end
