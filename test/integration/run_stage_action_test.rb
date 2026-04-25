require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/stage_action"

class RunStageActionTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT].each { |k| ENV.delete(k) }
  end

  def seed_inbox(dir, text = "stage action probe")
    capture_io do
      Hive::Commands::Init.new(dir).call
      Hive::Commands::New.new(File.basename(dir), text).call
    end
    inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
    [ inbox, File.basename(inbox) ]
  end

  def test_brainstorm_moves_inbox_to_brainstorm_and_runs
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _inbox, slug = seed_inbox(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(brainstorm, "brainstorm.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"

        capture_io { Hive::Commands::StageAction.new("brainstorm", slug).call }

        assert File.directory?(brainstorm)
        assert_equal :waiting, Hive::Markers.current(File.join(brainstorm, "brainstorm.md")).name
      end
    end
  end

  def test_plan_moves_complete_brainstorm_to_plan_and_runs
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        File.write(File.join(brainstorm, "brainstorm.md"), "## Requirements\n<!-- COMPLETE -->\n")
        plan = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(plan, "plan.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Plan\n<!-- COMPLETE -->\n"

        capture_io { Hive::Commands::StageAction.new("plan", slug).call }

        assert File.directory?(plan)
        assert_equal :complete, Hive::Markers.current(File.join(plan, "plan.md")).name
      end
    end
  end

  def test_plan_refuses_waiting_brainstorm
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        File.write(File.join(brainstorm, "brainstorm.md"), "## Round 1\n<!-- WAITING -->\n")

        _out, err, status = with_captured_exit { Hive::Commands::StageAction.new("plan", slug).call }

        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_includes err, "finish the current stage first"
      end
    end
  end

  def test_from_disambiguates_same_slug_stage_collision
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        plan = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(brainstorm)
        FileUtils.mkdir_p(plan)
        FileUtils.rm_rf(inbox)
        File.write(File.join(brainstorm, "brainstorm.md"), "## Requirements\n<!-- COMPLETE -->\n")
        File.write(File.join(plan, "plan.md"), "## Existing\n<!-- WAITING -->\n")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(plan, "plan.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Updated\n<!-- COMPLETE -->\n"

        capture_io { Hive::Commands::StageAction.new("plan", slug, from: "plan").call }

        assert File.directory?(brainstorm), "existing brainstorm task must not move"
        assert_equal :complete, Hive::Markers.current(File.join(plan, "plan.md")).name
      end
    end
  end
end
