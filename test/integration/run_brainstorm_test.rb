require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"

class RunBrainstormTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
       HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
       HIVE_FAKE_CLAUDE_HANG HIVE_FAKE_CLAUDE_LOG_DIR].each { |k| ENV.delete(k) }
  end

  def make_task_at_brainstorm(dir)
    project = File.basename(dir)
    capture_io do
      Hive::Commands::Init.new(dir).call
      Hive::Commands::New.new(project, "test brainstorm").call
    end
    inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
    target = File.join(dir, ".hive-state", "stages", "2-brainstorm", File.basename(inbox))
    FileUtils.mv(inbox, target)
    target
  end

  def test_brainstorm_writes_round1_and_waiting
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder = make_task_at_brainstorm(dir)
        brainstorm_md = File.join(folder, "brainstorm.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = brainstorm_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n### Q1. Scope?\n### A1.\n\n<!-- WAITING -->\n"

        capture_io { Hive::Commands::Run.new(folder).call }

        assert File.exist?(brainstorm_md), "brainstorm.md should be written"
        marker = Hive::Markers.current(brainstorm_md)
        assert_equal :waiting, marker.name
        log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
        assert_match(%r{\Ahive: 2-brainstorm/.* round_waiting\z}, log)
      end
    end
  end

  def test_brainstorm_complete_marker
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder = make_task_at_brainstorm(dir)
        brainstorm_md = File.join(folder, "brainstorm.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = brainstorm_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Requirements\n- foo\n<!-- COMPLETE -->\n"
        capture_io { Hive::Commands::Run.new(folder).call }
        assert_equal :complete, Hive::Markers.current(brainstorm_md).name
      end
    end
  end

  def test_dispatcher_rejects_invalid_path
    with_tmp_global_config do
      assert_raises(Hive::InvalidTaskPath) { Hive::Commands::Run.new("/tmp/random").call }
    end
  end

  def test_inbox_stage_raises_wrong_stage_with_exit_4
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(File.basename(dir), "no run inbox").call
        end
        inbox_task = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        _, err, status = with_captured_exit { Hive::Commands::Run.new(inbox_task).call }
        assert_equal Hive::ExitCodes::WRONG_STAGE, status,
                     "1-inbox is inert; running it must raise WrongStage (exit 4)"
        assert_includes err, "1-inbox/ is an inert capture zone"
      end
    end
  end
end
