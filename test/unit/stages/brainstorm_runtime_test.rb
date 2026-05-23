require "test_helper"
require "hive/config"
require "hive/stages/brainstorm"

class BrainstormRuntimeTest < Minitest::Test
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
end
