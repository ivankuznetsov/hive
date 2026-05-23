require "test_helper"
require "hive/claude_launcher"
require "hive/stages/base"
require "hive/task"

class ClaudeLauncherTest < Minitest::Test
  include HiveTestHelper

  def test_headless_mode_delegates_to_base_spawn_agent
    with_tmp_task do |task|
      captured = nil
      original = Hive::Stages::Base.method(:spawn_agent)
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
    ensure
      Hive::Stages::Base.define_singleton_method(:spawn_agent) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
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

  def test_stage_spawn_records_tmux_unavailable_marker
    with_tmp_task do |task|
      original = Hive::ClaudeLauncher.method(:launch!)
      Hive::ClaudeLauncher.define_singleton_method(:launch!) do |**_kwargs|
        raise Hive::AgentError, "tmux binary not runnable: tmux"
      end

      result = Hive::Stages::Base.spawn_claude!(
        task,
        { "claude" => { "mode" => "tmux" } },
        prompt: "prompt",
        add_dirs: [ task.folder ],
        cwd: task.folder,
        max_budget_usd: 1,
        timeout_sec: 1,
        log_label: "test",
        status_mode: :state_file_marker
      )

      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, result[:status]
      assert_equal :error, marker.name
      assert_equal "tmux_unavailable", marker.attrs["reason"]
      assert_match(/tmux binary not runnable/, marker.attrs["message"])
    ensure
      Hive::ClaudeLauncher.define_singleton_method(:launch!, original)
    end
  end

  def test_tmux_unavailable_error_is_narrower_than_any_tmux_message
    unavailable = Hive::AgentError.new("tmux 2.9 below minimum 3.0")
    duplicate = Hive::AgentError.new("tmux session hive-x already exists")

    assert Hive::ClaudeLauncher.tmux_unavailable_error?(unavailable)
    refute Hive::ClaudeLauncher.tmux_unavailable_error?(duplicate)
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
end
