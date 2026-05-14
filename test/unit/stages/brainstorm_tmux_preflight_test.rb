require "test_helper"
require "hive/stages/brainstorm_tmux"

class BrainstormTmuxPreflightTest < Minitest::Test
  include HiveTestHelper

  def test_preflight_tmux_accepts_minimum_supported_version
    with_tmp_dir do |dir|
      tmux = fake_tmux(dir, "tmux 3.0")

      assert_equal "3.0", Hive::Stages::BrainstormTmux.preflight_tmux!(tmux_bin: tmux)
    end
  end

  def test_preflight_tmux_rejects_missing_binary
    err = assert_raises(Hive::AgentError) do
      Hive::Stages::BrainstormTmux.preflight_tmux!(tmux_bin: "missing-tmux-for-hive")
    end

    assert_match(/tmux binary not runnable/, err.message)
  end

  def test_preflight_tmux_rejects_too_old_version
    with_tmp_dir do |dir|
      tmux = fake_tmux(dir, "tmux 2.9")

      err = assert_raises(Hive::AgentError) do
        Hive::Stages::BrainstormTmux.preflight_tmux!(tmux_bin: tmux)
      end

      assert_match(/below minimum/, err.message)
    end
  end

  private

  def fake_tmux(dir, output)
    path = File.join(dir, "tmux")
    File.write(path, <<~SH)
      #!/usr/bin/env bash
      echo "#{output}"
    SH
    File.chmod(0o755, path)
    path
  end
end
