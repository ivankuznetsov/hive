require "test_helper"
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
end
