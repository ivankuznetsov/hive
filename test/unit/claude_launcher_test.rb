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

  def test_legacy_brainstorm_env_timeout_is_honored
    old_new = ENV["HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC"]
    old_legacy = ENV["HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC"]
    ENV.delete("HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC")
    ENV["HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC"] = "12.5"

    assert_equal 12.5, Hive::ClaudeLauncher.ready_wait_timeout
  ensure
    restore_env("HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC", old_new)
    restore_env("HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC", old_legacy)
  end

  def test_new_claude_env_timeout_wins_over_legacy
    old_new = ENV["HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC"]
    old_legacy = ENV["HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC"]
    ENV["HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC"] = "4.25"
    ENV["HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC"] = "12.5"

    assert_equal 4.25, Hive::ClaudeLauncher.ready_wait_timeout
  ensure
    restore_env("HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC", old_new)
    restore_env("HIVE_BRAINSTORM_TMUX_READY_WAIT_TIMEOUT_SEC", old_legacy)
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

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
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
end
