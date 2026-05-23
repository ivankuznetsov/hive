require "test_helper"
require "hive/config"
require "hive/stages/brainstorm"

class BrainstormRuntimeTest < Minitest::Test
  def test_runtime_for_defaults_to_headless
    assert_equal :headless, Hive::Stages::Brainstorm.runtime_for({})
  end

  def test_runtime_for_returns_tmux_interactive
    cfg = { "brainstorm" => { "runtime" => "tmux_interactive" } }

    assert_equal :tmux_interactive, Hive::Stages::Brainstorm.runtime_for(cfg)
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
