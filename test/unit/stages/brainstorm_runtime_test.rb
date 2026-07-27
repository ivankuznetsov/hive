require "test_helper"
require "hive/config"
require "hive/markers"
require "hive/stages/brainstorm"
require "hive/task"

class BrainstormRuntimeTest < Minitest::Test
  include HiveTestHelper

  def test_runtime_for_defaults_to_global_tmux_mode
    assert_equal :tmux_interactive, Hive::Stages::Brainstorm.runtime_for({})
  end

  def test_runtime_for_uses_global_claude_mode
    cfg = { "claude" => { "mode" => "headless" } }

    assert_equal :headless, Hive::Stages::Brainstorm.runtime_for(cfg)
  end

  def test_runtime_for_honors_legacy_tmux_runtime_when_global_mode_absent
    cfg = { "brainstorm" => { "runtime" => "tmux_interactive" } }

    assert_equal :tmux_interactive, Hive::Stages::Brainstorm.runtime_for(cfg)
  end

  def test_runtime_for_honors_legacy_headless_runtime_when_global_mode_absent
    cfg = { "brainstorm" => { "runtime" => "headless" } }

    assert_equal :headless, Hive::Stages::Brainstorm.runtime_for(cfg)
  end

  def test_runtime_for_ignores_legacy_runtime_when_global_mode_is_present
    cfg = {
      Hive::Config::EXPLICIT_CLAUDE_MODE_KEY => true,
      "claude" => { "mode" => "tmux" },
      "brainstorm" => { "runtime" => "headless" }
    }

    assert_equal :tmux_interactive, Hive::Stages::Brainstorm.runtime_for(cfg)
  end

  def test_runtime_for_non_claude_brainstorm_agent_is_headless
    cfg = {
      "claude" => { "mode" => "tmux" },
      "brainstorm" => { "agent" => "codex" }
    }

    assert_equal :headless, Hive::Stages::Brainstorm.runtime_for(cfg)
  end

  def test_runtime_for_rejects_unknown_runtime
    err = assert_raises(Hive::ConfigError) do
      Hive::Stages::Brainstorm.runtime_for({ "brainstorm" => { "runtime" => "bogus" } })
    end

    assert_match(/brainstorm\.runtime/, err.message)
  end

  def test_action_for_preserves_unknown_marker_name
    assert_equal "none", Hive::Stages::Brainstorm.action_for(:none)
    assert_equal "paused", Hive::Stages::Brainstorm.action_for(:paused)
  end

  # G8 mutation safety: `cfg_with_claude_mode` is the helper that runs
  # before the brainstorm spawn when the global mode is forced to
  # `:headless`. It MUST NOT mutate the caller's cfg - the same Hash
  # is threaded through many other stage helpers in the same run.
  def test_cfg_with_claude_mode_does_not_mutate_caller_cfg
    original = { "claude" => { "mode" => "tmux" } }
    snapshot = Marshal.load(Marshal.dump(original))

    forced = Hive::Stages::Brainstorm.cfg_with_claude_mode(original, :headless)

    assert_equal "headless", forced.dig("claude", "mode"),
                 "returned cfg has the forced mode"
    assert_equal snapshot, original,
                 "caller's cfg must not change (top-level OR nested keys)"
    refute_same original, forced,
                "returned cfg must be a new Hash"
    refute_same original["claude"], forced["claude"],
                "returned cfg.claude must be a new Hash so a later in-place edit cannot leak"
  end

  def test_cfg_with_claude_mode_handles_missing_claude_block
    original = {}
    forced = Hive::Stages::Brainstorm.cfg_with_claude_mode(original, :headless)
    assert_equal "headless", forced.dig("claude", "mode")
    assert_equal({}, original, "original cfg without claude key must remain empty")
  end

  def test_headless_failed_spawn_without_artifact_becomes_typed_brainstorm_error
    with_brainstorm_task do |task|
      profile = Hive::AgentProfiles.lookup(:codex)
      spawn = lambda do |_task, **_kwargs|
        {
          status: :error,
          failure_origin: "budget_exhausted",
          failure_details: {
            provider: "claude",
            subtype: "error_max_budget_usd",
            configured_cap_usd: 1.0,
            observed_cost_usd: 1.047936,
            diagnostic: "Reached maximum budget ($1)",
            remedy: "raise_stage_budget"
          },
          error_message: "agent exhausted its per-run budget"
        }
      end

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        result = Hive::Stages::Brainstorm.run_headless!(
          task, brainstorm_cfg, profile: profile
        )

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal "budget_exhausted", marker.attrs.fetch("reason")
        assert_equal "raise_stage_budget", marker.attrs.fetch("remedy")
      end
    end
  end

  def test_tmux_failed_spawn_without_artifact_becomes_typed_brainstorm_error
    with_brainstorm_task do |task|
      profile = Hive::AgentProfiles.lookup(:claude)
      spawn = ->(_task, _cfg, **_kwargs) { { status: :error, error_message: "tmux session died" } }

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_claude_with_tmux_marker!, spawn) do
        result = Hive::Stages::Brainstorm.run_claude!(
          task, brainstorm_cfg, profile: profile
        )

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal "brainstorm_agent_failed", marker.attrs.fetch("reason")
        assert_includes marker.attrs.fetch("message"), "tmux session died"
      end
    end
  end

  def test_invalid_waiting_artifact_cannot_complete_brainstorm
    with_brainstorm_task do |task|
      profile = Hive::AgentProfiles.lookup(:codex)
      spawn = lambda do |spawned_task, **_kwargs|
        File.write(spawned_task.state_file, "not a brainstorm\n<!-- WAITING -->\n")
        { status: :waiting }
      end

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        result = Hive::Stages::Brainstorm.run_headless!(
          task, brainstorm_cfg, profile: profile
        )

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal "brainstorm_artifact_invalid", marker.attrs.fetch("reason")
      end
    end
  end

  def test_changed_valid_artifact_wins_over_trailing_spawn_failure
    with_brainstorm_task do |task|
      profile = Hive::AgentProfiles.lookup(:codex)
      spawn = lambda do |spawned_task, **_kwargs|
        File.write(
          spawned_task.state_file,
          "## Round 1\n### Q1. Scope?\n### A1.\n<!-- WAITING -->\n"
        )
        { status: :error, failure_origin: "budget_exhausted" }
      end

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        result = Hive::Stages::Brainstorm.run_headless!(
          task, brainstorm_cfg, profile: profile
        )

        assert_equal({ commit: "round_waiting", status: :waiting }, result)
        assert_equal :waiting, Hive::Markers.current(task.state_file).name
      end
    end
  end

  def test_unchanged_preexisting_artifact_does_not_hide_failed_spawn
    with_brainstorm_task do |task|
      File.write(
        task.state_file,
        "## Round 1\n### Q1. Scope?\n### A1.\n<!-- WAITING -->\n"
      )
      profile = Hive::AgentProfiles.lookup(:codex)
      spawn = ->(_task, **_kwargs) { { status: :error, error_message: "preflight failed" } }

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        result = Hive::Stages::Brainstorm.run_headless!(
          task, brainstorm_cfg, profile: profile
        )

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ commit: "error", status: :error }, result)
        assert_equal "brainstorm_agent_failed", marker.attrs.fetch("reason")
      end
    end
  end

  private

  def brainstorm_cfg
    {
      "budget_usd" => { "brainstorm" => 1.0 },
      "timeout_sec" => { "brainstorm" => 30 }
    }
  end

  def with_brainstorm_task
    with_tmp_dir do |root|
      folder = File.join(
        root, ".hive-state", "stages", "2-brainstorm",
        "brainstorm-test-260725-abcd"
      )
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "idea.md"), "Build a reliable system.\n")
      yield Hive::Task.new(folder)
    end
  end
end
