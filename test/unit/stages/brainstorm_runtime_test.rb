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
end
