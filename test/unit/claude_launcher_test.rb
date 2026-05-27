require "test_helper"
require "hive/claude_launcher"
require "hive/stages/base"
require "hive/task"

class ClaudeLauncherTest < Minitest::Test
  include HiveTestHelper

  def test_headless_mode_delegates_to_base_spawn_agent
    with_tmp_task do |task|
      captured = nil
      original = Hive::Stages::Base.singleton_class.instance_method(:spawn_agent)
      capture_unbound_method_on(Hive::Stages::Base, :spawn_agent, original) do
        Hive::Stages::Base.define_singleton_method(:spawn_agent) do |spawn_task, **kwargs|
          captured = [ spawn_task, kwargs ]
          { status: :complete }
        end

        result = Hive::ClaudeLauncher.launch!(
          task: task,
          cfg: { "claude" => { "mode" => "headless" } },
          prompt: "prompt",
          add_dirs: [ task.folder ],
          cwd: task.folder,
          max_budget_usd: 1,
          timeout_sec: 1,
          log_label: "test",
          session_name: "hive-test-session",
          status_mode: :state_file_marker
        )

        assert_equal({ status: :complete }, result)
        assert_equal task, captured.fetch(0)
        assert_equal "prompt", captured.fetch(1).fetch(:prompt)
        assert_equal :claude, captured.fetch(1).fetch(:profile).name
      end
    end
  end

  def test_launcher_rejects_non_claude_profile
    with_tmp_task do |task|
      err = assert_raises(Hive::AgentError) do
        Hive::ClaudeLauncher.launch!(
          task: task,
          cfg: { "claude" => { "mode" => "headless" } },
          prompt: "prompt",
          add_dirs: [],
          cwd: task.folder,
          max_budget_usd: 1,
          timeout_sec: 1,
          log_label: "test",
          session_name: "hive-test-session",
          profile: Hive::AgentProfiles.lookup(:codex)
        )
      end

      assert_match(/only supports the claude profile/, err.message)
    end
  end

  def test_tmux_session_name_includes_stage_name
    with_tmp_task(stage: "3-plan") do |task|
      assert_equal "hive-3-plan-#{task.slug}", Hive::ClaudeLauncher.tmux_session_name("3-plan", task)
      assert_equal "hive-4-execute-#{task.slug}", Hive::ClaudeLauncher.tmux_session_name("4-execute", task)
    end
  end

  def test_session_handle_passes_deadline_to_send_prompt_and_wait
    with_tmp_task do |task|
      captured = nil
      original = Hive::ClaudeLauncher.method(:send_prompt_and_wait!)
      Hive::ClaudeLauncher.define_singleton_method(:send_prompt_and_wait!) do |**kwargs|
        captured = kwargs
        { status: :ok }
      end

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      handle = Hive::ClaudeLauncher::SessionHandle.new(task: task, runner: Object.new)
      handle.send_and_wait!(prompt: "prompt", timeout_sec: 5, deadline: deadline)

      assert_equal deadline, captured.fetch(:deadline)
    ensure
      Hive::ClaudeLauncher.singleton_class.send(:remove_method, :send_prompt_and_wait!)
      Hive::ClaudeLauncher.define_singleton_method(:send_prompt_and_wait!, original) if original
    end
  end

  def test_prepare_claude_session_uses_caller_deadline_before_ready_timeout
    runner = Object.new
    runner.define_singleton_method(:name) { "hive-test-session" }
    runner.define_singleton_method(:session_exists?) { true }
    runner.define_singleton_method(:capture_pane_tail) { |bytes:| "Claude Code v2.1.128\nstill working" }

    monotonic_now = 1_000.0
    sleeps = []
    with_replaced_singleton_method(Process, :clock_gettime, ->(_clock, *_args) { monotonic_now }) do
      with_replaced_singleton_method(Hive::ClaudeLauncher, :sleep, lambda { |seconds|
        sleeps << seconds
        monotonic_now += seconds
      }) do
        err = assert_raises(Hive::AgentError) do
          Hive::ClaudeLauncher.prepare_claude_session!(runner, deadline: monotonic_now + 0.5)
        end
        assert_match(/before caller deadline/, err.message)
      end
    end

    assert_in_delta 0.5, sleeps.sum, 0.001
  end

  def test_send_prompt_and_wait_clamps_wait_timeout_to_remaining_deadline
    with_tmp_task do |task|
      runner = Object.new
      sent_prompts = []
      runner.define_singleton_method(:send_prompt) { |prompt| sent_prompts << prompt }

      monotonic_now = 1_000.0
      captured_timeout = nil
      captured_deadline = nil
      with_replaced_singleton_method(Process, :clock_gettime, ->(_clock, *_args) { monotonic_now }) do
        with_replaced_singleton_method(Hive::ClaudeLauncher, :prepare_claude_session!, lambda { |_runner, deadline:|
          captured_deadline = deadline
          monotonic_now += 1
          true
        }) do
          with_replaced_singleton_method(Hive::ClaudeLauncher, :wait_for_status, lambda { |_task, _runner, timeout, *_args|
            captured_timeout = timeout
            { status: :ok, final_message: nil, final_message_source: nil }
          }) do
            with_replaced_singleton_method(Hive::ClaudeLauncher, :capture_pane_log, ->(*_args) { }) do
              result = Hive::ClaudeLauncher.send_prompt_and_wait!(
                task: task,
                runner: runner,
                prompt: "prompt",
                timeout_sec: 10,
                deadline: 1_005.0,
                status_mode: :output_file_exists
              )
              assert_equal :ok, result.fetch(:status)
            end
          end
        end
      end

      assert_equal [ "prompt" ], sent_prompts
      assert_in_delta 1_005.0, captured_deadline, 0.001
      assert_in_delta 4.0, captured_timeout, 0.001
    end
  end

  def test_send_prompt_and_wait_returns_timeout_when_readiness_consumes_deadline
    with_tmp_task do |task|
      runner = Object.new
      runner.define_singleton_method(:send_prompt) { |_prompt| flunk "prompt must not be sent after deadline" }

      monotonic_now = 1_000.0
      with_replaced_singleton_method(Process, :clock_gettime, ->(_clock, *_args) { monotonic_now }) do
        with_replaced_singleton_method(Hive::ClaudeLauncher, :prepare_claude_session!, lambda { |_runner, deadline:|
          monotonic_now = deadline
          true
        }) do
          result = Hive::ClaudeLauncher.send_prompt_and_wait!(
            task: task,
            runner: runner,
            prompt: "prompt",
            timeout_sec: 10,
            deadline: 1_001.0,
            status_mode: :output_file_exists
          )
          assert_equal :timeout, result.fetch(:status)
          assert_match(/deadline reached before prompt/, result.fetch(:error_message))
        end
      end
    end
  end

  def test_legacy_brainstorm_env_timeout_is_honored
    with_env(
      "HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC" => nil,
      "HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC" => "12.5"
    ) do
      assert_equal 12.5, Hive::ClaudeLauncher.ready_wait_timeout
    end
  end

  def test_new_claude_env_timeout_wins_over_legacy
    with_env(
      "HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC" => "4.25",
      "HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC" => "12.5"
    ) do
      assert_equal 4.25, Hive::ClaudeLauncher.ready_wait_timeout
    end
  end

  def test_claude_ready_timeout_inherits_new_shared_ready_timeout_when_specific_unset
    with_env(
      "HIVE_CLAUDE_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => nil,
      "HIVE_BRAINSTORM_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => nil,
      "HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC" => "8.75",
      "HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC" => "12.5"
    ) do
      assert_equal 8.75, Hive::ClaudeLauncher.claude_ready_wait_timeout
    end
  end

  def test_claude_ready_timeout_inherits_legacy_shared_ready_timeout_when_specific_unset
    with_env(
      "HIVE_CLAUDE_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => nil,
      "HIVE_BRAINSTORM_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => nil,
      "HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC" => nil,
      "HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC" => "12.5"
    ) do
      assert_equal 12.5, Hive::ClaudeLauncher.claude_ready_wait_timeout
    end
  end

  def test_claude_ready_timeout_specific_setting_wins_over_shared_ready_timeout
    with_env(
      "HIVE_CLAUDE_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => "30.5",
      "HIVE_BRAINSTORM_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => "40.5",
      "HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC" => "8.75",
      "HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC" => "12.5"
    ) do
      assert_equal 30.5, Hive::ClaudeLauncher.claude_ready_wait_timeout
    end
  end

  def test_claude_ready_timeout_legacy_specific_setting_wins_over_shared_ready_timeout
    with_env(
      "HIVE_CLAUDE_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => nil,
      "HIVE_BRAINSTORM_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => "40.5",
      "HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC" => "8.75",
      "HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC" => "12.5"
    ) do
      assert_equal 40.5, Hive::ClaudeLauncher.claude_ready_wait_timeout
    end
  end

  def test_claude_ready_timeout_valid_specific_setting_wins_over_invalid_shared_timeout
    with_env(
      "HIVE_CLAUDE_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => "30.5",
      "HIVE_BRAINSTORM_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => nil,
      "HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC" => "not-a-float",
      "HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC" => nil
    ) do
      assert_equal 30.5, Hive::ClaudeLauncher.claude_ready_wait_timeout
    end
  end

  def test_claude_ready_timeout_raises_for_invalid_inherited_shared_timeout
    with_env(
      "HIVE_CLAUDE_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => nil,
      "HIVE_BRAINSTORM_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => nil,
      "HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC" => "not-a-float",
      "HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC" => nil
    ) do
      assert_raises(ArgumentError) do
        Hive::ClaudeLauncher.claude_ready_wait_timeout
      end
    end
  end

  def test_claude_ready_timeout_keeps_long_default_without_shared_override
    with_env(
      "HIVE_CLAUDE_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => nil,
      "HIVE_BRAINSTORM_TMUX_CLAUDE_READY_WAIT_TIMEOUT_SEC" => nil,
      "HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC" => nil,
      "HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC" => nil
    ) do
      assert_equal Hive::ClaudeLauncher::CLAUDE_READY_WAIT_TIMEOUT_SEC,
                   Hive::ClaudeLauncher.claude_ready_wait_timeout
    end
  end

  def test_claude_ready_prompt_accepts_observed_prompt_on_last_nonblank_line
    pane = "Claude Code v2.1.133\nTip: try refactor\n\n❯ Try \"refactor <filepath>\""

    assert Hive::ClaudeLauncher.claude_ready_prompt?(pane)
  end

  def test_claude_ready_prompt_rejects_stale_prompt_marker_in_scrollback
    pane = "Claude Code v2.1.133\n❯ Try \"refactor <filepath>\"\n\nbackground indexing update"

    refute Hive::ClaudeLauncher.claude_ready_prompt?(pane)
  end

  def test_claude_ready_prompt_accepts_current_ready_prompt_with_stale_trust_scrollback
    pane = "Quick safety check\n❯ 1. Yes, I trust this folder\nEnter to confirm\n" \
           "Claude Code v2.1.133\n❯ Try \"refactor <filepath>\""

    refute Hive::ClaudeLauncher.claude_trust_prompt?(pane)
    assert Hive::ClaudeLauncher.claude_ready_prompt?(pane)
  end

  def test_claude_ready_prompt_accepts_current_ready_prompt_with_stale_permission_scrollback
    pane = "Claude Code v2.1.133\nDo you want to make this edit?\n❯ 1. Yes\n" \
           "Claude Code v2.1.133\n❯ Try \"refactor <filepath>\""

    assert Hive::ClaudeLauncher.claude_ready_prompt?(pane)
  end

  def test_claude_ready_prompt_rejects_numbered_menu_option_after_copy_drift
    pane = "Claude Code v2.1.133\nProceed with the action?\n❯ 1. Yes"

    refute Hive::ClaudeLauncher.claude_ready_prompt?(pane)
  end

  def test_claude_trust_prompt_matches_observed_folder_trust_prompt
    pane = "Quick safety check\n❯ 1. Yes, I trust this folder\nEnter to confirm"

    assert Hive::ClaudeLauncher.claude_trust_prompt?(pane)
  end

  def test_spawn_claude_bang_propagates_agent_error_unchanged
    # `spawn_claude!` no longer catches tmux-unavailable AgentErrors;
    # the propagation is what lets the review stage's outer rescue
    # land `:review_error reason="tmux_unavailable"` against the real
    # task instead of writing the wrong marker shape to a synthetic
    # task's state_file. Per-stage callers that want the marker shape
    # use `spawn_claude_with_tmux_marker!` (see below).
    with_tmp_task do |task|
      original = Hive::ClaudeLauncher.method(:launch!)
      capture_unbound_method(:launch!, original) do
        Hive::ClaudeLauncher.define_singleton_method(:launch!) do |**_kwargs|
          raise Hive::AgentError, "tmux binary not runnable: tmux"
        end

        assert_raises(Hive::AgentError) do
          Hive::Stages::Base.spawn_claude!(
            task,
            { "claude" => { "mode" => "tmux" } },
            prompt: "prompt",
            add_dirs: [ task.folder ],
            cwd: task.folder,
            max_budget_usd: 1,
            timeout_sec: 1,
            log_label: "test",
            session_name: "hive-test-spawn-claude",
            status_mode: :state_file_marker
          )
        end
      end
    end
  end

  def test_spawn_claude_with_tmux_marker_records_marker
    with_tmp_task do |task|
      original = Hive::ClaudeLauncher.method(:launch!)
      capture_unbound_method(:launch!, original) do
        Hive::ClaudeLauncher.define_singleton_method(:launch!) do |**_kwargs|
          raise Hive::AgentError, "tmux binary not runnable: tmux"
        end

        result = nil
        _out, _err = capture_io do
          result = Hive::Stages::Base.spawn_claude_with_tmux_marker!(
            task,
            { "claude" => { "mode" => "tmux" } },
            prompt: "prompt",
            add_dirs: [ task.folder ],
            cwd: task.folder,
            max_budget_usd: 1,
            timeout_sec: 1,
            log_label: "test",
            session_name: "hive-test-spawn-claude-with-marker",
            status_mode: :state_file_marker
          )
        end

        marker = Hive::Markers.current(task.state_file)
        assert_equal :error, result[:status]
        assert_equal :error, marker.name
        assert_equal "tmux_unavailable", marker.attrs["reason"]
        assert_match(/tmux binary not runnable/, marker.attrs["message"])
      end
    end
  end

  TMUX_UNAVAILABLE_MESSAGES = [
    "tmux not runnable: tmux foo",
    "tmux binary not runnable: tmux (ENOENT: foo)",
    "could not parse tmux -V output: \"unexpected\"",
    "tmux 2.9 below minimum 3.0"
  ].freeze

  # Q2: parameterize so EVERY entry of TMUX_UNAVAILABLE_PATTERNS is
  # covered. A regression that broadens or narrows the regex is now
  # immediately visible — not just for the one entry the original
  # test happened to assert.
  def test_tmux_unavailable_patterns_each_match
    TMUX_UNAVAILABLE_MESSAGES.each do |msg|
      err = Hive::AgentError.new(msg)
      assert Hive::ClaudeLauncher.tmux_unavailable_error?(err),
             "expected #{msg.inspect} to count as tmux unavailable"
    end
  end

  def test_tmux_unavailable_excludes_session_collision_and_startup_timeout
    [
      "tmux session hive-x already exists",
      "tmux session hive-x did not start"
    ].each do |msg|
      err = Hive::AgentError.new(msg)
      refute Hive::ClaudeLauncher.tmux_unavailable_error?(err),
             "#{msg.inspect} is a transient/per-session failure, not 'tmux missing'"
    end
  end

  def test_tmux_session_name_truncates_at_250_bytes
    long_slug = ("a" * 300)
    task = Struct.new(:slug, :folder, :stage_name).new(long_slug, "/tmp", "2-brainstorm")
    name = Hive::ClaudeLauncher.tmux_session_name("2-brainstorm", task)
    assert_operator name.bytesize, :<=, 250
    assert name.start_with?("hive-2-brainstorm-")
  end

  def test_tmux_session_name_handles_multibyte_slug
    multi = "тест-" + ("я" * 200)
    task = Struct.new(:slug, :folder, :stage_name).new(multi, "/tmp", "2-brainstorm")
    name = Hive::ClaudeLauncher.tmux_session_name("2-brainstorm", task)
    # 250-byte slice can land mid-codepoint; that's an explicit
    # behaviour choice (tmux session names are byte-bounded). Assert
    # only the byte cap; do NOT assert UTF-8 validity.
    assert_operator name.bytesize, :<=, 250
  end

  # G5: enumerate every stage_short_name the orchestrator passes to
  # tmux_session_name. A copy-paste regression that re-used another
  # stage's short name (e.g. review-fix-pass1 vs review-pass1) would
  # produce a session-name collision when the runner tried to keep both
  # alive across a pass; pin the per-stage uniqueness contract.
  def test_tmux_session_names_are_unique_across_orchestrator_call_sites
    task = Struct.new(:slug, :folder, :stage_name).new("slug-260522-abcd", "/tmp", "_")
    names = [
      "2-brainstorm",
      "3-plan",
      "4-execute",
      "5-open-pr",
      "7-artifacts",
      "8-finalize",
      "6-review-pass1",
      "6-review-pass2",
      "6-review-fix-pass1",
      "6-review-fix-pass2",
      "6-review-triage-pass1",
      "6-review-ci-fix-attempt1",
      "6-review-ci-fix-attempt2",
      "6-review-browser-pass1-attempt1",
      "6-review-browser-pass1-attempt2"
    ].map { |stage| Hive::ClaudeLauncher.tmux_session_name(stage, task) }

    assert_equal names.size, names.uniq.size,
                 "every stage_short_name must map to a unique tmux session name: " \
                 "duplicates=#{names.tally.select { |_, n| n > 1 }.keys.inspect}"
  end

  # G5: a long slug that shares a 250-byte prefix with another slug
  # may produce a colliding session name when the differing tail
  # lives past the 250-byte truncation boundary. The current
  # implementation simply byte-slices, so today the names collide;
  # a future safer mitigation (hash-suffix, structured-truncation)
  # would produce distinct names without violating any caller
  # contract. Assert the BOUNDARY behaviour — names produced from
  # the same stage + 250-byte-prefix inputs are byte-bounded the
  # same way — without pinning the specific collision outcome.
  def test_tmux_session_names_byte_bound_on_shared_prefix_within_same_stage
    long_slug = "a" * 300
    task = Struct.new(:slug, :folder, :stage_name).new(long_slug, "/tmp", "2-brainstorm")
    name_a = Hive::ClaudeLauncher.tmux_session_name("2-brainstorm", task)

    other_task = Struct.new(:slug, :folder, :stage_name).new("#{long_slug}-DIFFERENT-TAIL",
                                                              "/tmp", "2-brainstorm")
    name_b = Hive::ClaudeLauncher.tmux_session_name("2-brainstorm", other_task)

    [ name_a, name_b ].each do |n|
      assert_operator n.bytesize, :<=, 250,
                       "every session name must respect tmux's byte cap regardless of slug length"
      assert n.start_with?("hive-2-brainstorm-"),
             "stage-prefix must survive byte-bound truncation"
    end
    # Either outcome is acceptable: today's byte-slice implementation
    # collides; a future hash-suffix mitigation would not. Both are
    # safer than silently mangling the slug end mid-codepoint.
    if name_a == name_b
      assert_equal name_a.bytesize, name_b.bytesize,
                   "if names collide they collide at the truncation boundary"
    else
      refute_equal name_a, name_b,
                   "distinct slug tails should yield distinct session names when the implementation has room"
    end
  end

  private

  def with_tmp_task(stage: "2-brainstorm")
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", stage, "slug-260522-abcd")
      FileUtils.mkdir_p(folder)
      yield Hive::Task.new(folder)
    end
  end

  # Unify on the UnboundMethod capture+rebind stub pattern used in
  # brainstorm_tmux_sentinel_test.rb (Q1 / pr-test-analyzer #9). The
  # earlier `define_singleton_method` lambda-rebind approach could
  # leak when minitest re-ordered tests; capturing the original
  # UnboundMethod and restoring it via `define_method` is symmetric
  # and survives reordering.
  def capture_unbound_method(method_name, original_unbound_or_method, &block)
    capture_unbound_method_on(Hive::ClaudeLauncher, method_name, original_unbound_or_method, &block)
  end

  def capture_unbound_method_on(mod, method_name, original_unbound_or_method)
    yield
  ensure
    if original_unbound_or_method.is_a?(UnboundMethod)
      mod.singleton_class.send(:define_method, method_name, original_unbound_or_method)
    elsif original_unbound_or_method.is_a?(Method)
      mod.define_singleton_method(method_name, original_unbound_or_method)
    end
  end

  public

  def test_prepare_claude_session_fails_when_session_disappears_before_ready
    runner = Struct.new(:name) do
      def session_exists? = false
    end.new("gone-session")

    err = assert_raises(Hive::AgentError) do
      Hive::ClaudeLauncher.prepare_claude_session!(runner)
    end

    assert_match(/terminated before becoming ready/, err.message)
  end

  def test_wait_for_status_dispatches_exit_output_and_unknown_modes
    with_tmp_task do |task|
      runner = Struct.new(:tail) do
        def capture_pane_tail(bytes:) = tail
      end.new("Claude Code\n❯")
      output = File.join(task.folder, "expected.md")
      File.write(output, "done")

      output_result = Hive::ClaudeLauncher.wait_for_status(
        task, runner, 0, :output_file_exists, output, "reviewer"
      )
      assert_equal :ok, output_result.fetch(:status)
      assert_equal "reviewer", output_result.fetch(:log_label)
    end

    with_tmp_task do |task|
      runner = Struct.new(:tail) do
        def capture_pane_tail(bytes:) = tail
      end.new("")
      missing_output = File.join(task.folder, "missing.md")
      File.write(Hive::ClaudeLauncher.done_path(task), "done")

      done_result = Hive::ClaudeLauncher.wait_for_status(
        task, runner, 0, :exit_code_only, missing_output, "ci"
      )
      assert_equal :ok, done_result.fetch(:status)
      assert_equal "ci", done_result.fetch(:log_label)

      assert_raises(ArgumentError) do
        Hive::ClaudeLauncher.wait_for_status(task, runner, 0, :mystery, missing_output, "x")
      end
    end
  end

  def test_wait_for_expected_output_accepts_ready_prompt_without_done_file
    with_tmp_task do |task|
      output = File.join(task.folder, "result.md")
      File.write(output, "review findings")
      runner = Struct.new(:tail) do
        def capture_pane_tail(bytes:) = tail
      end.new("Claude Code v2\n❯")

      result = Hive::ClaudeLauncher.wait_for_expected_output(task, runner, 1, output, "review")

      assert_equal({ status: :ok, log_label: "review" }, result)
    end
  end

  def test_wait_for_expected_output_reports_repeated_tmux_errors
    with_tmp_task do |task|
      output = File.join(task.folder, "result.md")
      File.write(output, "review findings")
      runner = Struct.new(:name) do
        def capture_pane_tail(bytes:)
          raise Hive::TmuxError, "pane unreadable"
        end
      end.new("broken")

      with_replaced_singleton_method(Hive::ClaudeLauncher, :sleep, ->(_seconds) { }) do
        result = Hive::ClaudeLauncher.wait_for_expected_output(task, runner, 10, output, "review")
        assert_equal :error, result.fetch(:status)
        assert_match(/tmux_pane_unreadable: pane unreadable/, result.fetch(:error_message))
      end
    end
  end

  def test_wait_for_expected_output_times_out_when_file_missing
    with_tmp_task do |task|
      runner = Struct.new(:tail) do
        def capture_pane_tail(bytes:) = tail
      end.new("")
      output = File.join(task.folder, "missing.md")

      result = Hive::ClaudeLauncher.wait_for_expected_output(task, runner, 0, output, "review")

      assert_equal :timeout, result.fetch(:status)
      assert_match(/missing or empty/, result.fetch(:error_message))
    end
  end

  def test_wait_for_done_signal_uses_result_json_status_and_timeout
    with_tmp_task do |task|
      File.write(Hive::ClaudeLauncher.done_path(task), "done")
      File.write(Hive::ClaudeLauncher.result_path(task), JSON.generate("status" => "failed"))

      failed = Hive::ClaudeLauncher.wait_for_done_signal(task, nil, 1, "ci")
      assert_equal :failed, failed.fetch(:status)
      assert_match(/failed/, failed.fetch(:error_message))
    end

    with_tmp_task do |task|
      timeout = Hive::ClaudeLauncher.wait_for_done_signal(task, nil, 0, "ci")
      assert_equal :timeout, timeout.fetch(:status)
      assert_match(/stop hook did not signal/, timeout.fetch(:error_message))
    end
  end

  def test_read_result_json_status_handles_all_fallback_shapes
    with_tmp_task do |task|
      assert_nil Hive::ClaudeLauncher.read_result_json_status(task)

      FileUtils.touch(Hive::ClaudeLauncher.result_path(task))
      assert_nil Hive::ClaudeLauncher.read_result_json_status(task)

      File.write(Hive::ClaudeLauncher.result_path(task), JSON.generate("status" => "success"))
      assert_equal :ok, Hive::ClaudeLauncher.read_result_json_status(task)

      File.write(Hive::ClaudeLauncher.result_path(task), JSON.generate("status" => ""))
      assert_nil Hive::ClaudeLauncher.read_result_json_status(task)

      File.write(Hive::ClaudeLauncher.result_path(task), JSON.generate("status" => "cancelled"))
      assert_equal :cancelled, Hive::ClaudeLauncher.read_result_json_status(task)

      File.write(Hive::ClaudeLauncher.result_path(task), JSON.generate([ "not", "a", "hash" ]))
      assert_nil Hive::ClaudeLauncher.read_result_json_status(task)

      File.write(Hive::ClaudeLauncher.result_path(task), "{")
      assert_nil Hive::ClaudeLauncher.read_result_json_status(task)
    end
  end

  def test_wait_for_terminal_marker_preserves_pane_unreadable_error_on_timeout
    with_tmp_task do |task|
      Hive::Markers.set(task.state_file, :error, reason: "tmux_pane_unreadable", message: "pane gone")
      runner = Struct.new(:tail) do
        def capture_pane_tail(bytes:) = tail
      end.new("")

      marker = Hive::ClaudeLauncher.wait_for_terminal_marker(task, runner, 0)

      assert_equal :error, marker.name
      assert_equal "tmux_pane_unreadable", marker.attrs.fetch("reason")
    end
  end

  def test_signal_cleanup_helpers_ignore_unlink_races
    with_tmp_task do |task|
      File.write(Hive::ClaudeLauncher.result_path(task), "{}")
      result_path = Hive::ClaudeLauncher.result_path(task)
      with_replaced_singleton_method(File, :delete, lambda { |path|
        raise Errno::ENOENT if path == result_path
        true
      }) do
        assert_nil Hive::ClaudeLauncher.reset_signal_files(task)
      end
    end

    with_tmp_task do |task|
      output = File.join(task.folder, "expected.md")
      File.write(output, "x")
      with_replaced_singleton_method(File, :delete, ->(_path) { raise Errno::ENOENT }) do
        assert_nil Hive::ClaudeLauncher.cleanup_expected_output(output)
      end
    end
  end

  def test_cleanup_scratch_ignores_directory_races
    with_tmp_task do |task|
      scratch = File.join(task.folder, ".claude", "settings.json")
      FileUtils.mkdir_p(File.dirname(scratch))
      File.write(scratch, "{}")

      with_replaced_singleton_method(Dir, :rmdir, ->(_dir) { raise Errno::ENOTEMPTY }) do
        assert_nil Hive::ClaudeLauncher.cleanup_scratch(scratch)
      end
    end
  end

  def test_cleanup_scratch_restores_project_owned_settings_from_backup
    with_tmp_task do |task|
      settings = File.join(task.folder, ".claude", "settings.json")
      FileUtils.mkdir_p(File.dirname(settings))
      backup = "#{settings}#{Hive::StopHookInstaller::BACKUP_SUFFIX}"
      # Simulate state mid-spawn: backup holds the project's original
      # content, settings.json holds the hive-installed Stop-hook stub.
      File.write(backup, %({"enabledPlugins":{"frontend-design@official":true}}))
      File.write(settings, %({"hooks":{"Stop":[]}}))
      File.chmod(0o444, settings) # installer marks it read-only

      Hive::ClaudeLauncher.cleanup_scratch(settings)

      refute File.exist?(backup), "backup must be removed after restoring"
      assert File.exist?(settings),
             "settings.json must remain — restored from backup, not deleted"
      assert_equal %({"enabledPlugins":{"frontend-design@official":true}}),
                   File.read(settings),
                   "restored content must match the project's original byte-for-byte"
    end
  end

  def test_cleanup_scratch_deletes_when_no_backup_exists
    with_tmp_task do |task|
      settings = File.join(task.folder, ".claude", "settings.json")
      FileUtils.mkdir_p(File.dirname(settings))
      File.write(settings, "{}")

      Hive::ClaudeLauncher.cleanup_scratch(settings)

      refute File.exist?(settings),
             "no-backup case (project did not own the file) must keep the delete-on-cleanup semantics"
    end
  end

  def test_safe_with_log_mentions_task_folder_when_available
    task = Struct.new(:folder).new("/tmp/example-task")

    _out, err = capture_io do
      result = Hive::ClaudeLauncher.safe_with_log(task, "cleanup") { raise "boom" }
      assert_nil result
    end

    assert_match(/example-task/, err)
    assert_match(/cleanup/, err)
  end
end
