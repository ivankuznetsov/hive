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


  def test_preflight_tmux_rejects_nonzero_version_command
    with_tmp_dir do |dir|
      tmux = fake_tmux(dir, "tmux 3.6", exit_status: 42, err: "boom")

      err = assert_raises(Hive::AgentError) do
        Hive::Stages::BrainstormTmux.preflight_tmux!(tmux_bin: tmux)
      end

      assert_match(/tmux not runnable/, err.message)
      assert_match(/boom/, err.message)
    end
  end

  def test_preflight_tmux_rejects_unparseable_version_output
    with_tmp_dir do |dir|
      tmux = fake_tmux(dir, "definitely not tmux")

      err = assert_raises(Hive::AgentError) do
        Hive::Stages::BrainstormTmux.preflight_tmux!(tmux_bin: tmux)
      end

      assert_match(/could not parse/, err.message)
    end
  end

  def test_tmux_status_distinguishes_old_version_from_missing_binary
    with_tmp_dir do |dir|
      old_tmux = fake_tmux(dir, "tmux 2.9")

      old_status, old_message = Hive::Stages::BrainstormTmux.tmux_status(tmux_bin: old_tmux)
      missing_status, missing_message = Hive::Stages::BrainstormTmux.tmux_status(
        tmux_bin: "missing-tmux-for-hive"
      )

      assert_equal :version_too_old, old_status
      assert_match(/below minimum/, old_message)
      assert_equal :missing, missing_status
      assert_match(/not runnable/, missing_message)
    end
  end

  private

  def fake_tmux(dir, output, exit_status: 0, err: "")
    path = File.join(dir, "tmux")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      $stderr.write(#{err.inspect})
      puts #{output.inspect}
      exit #{exit_status}
    RUBY
    File.chmod(0o755, path)
    path
  end
end
