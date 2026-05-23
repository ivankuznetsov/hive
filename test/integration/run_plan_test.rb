require "test_helper"
require "json"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"

class RunPlanTest < Minitest::Test
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

  def test_plan_stage_writes_plan_md
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(File.basename(dir), "plan stage test").call
        end
        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(inbox)
        plan_dir = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(File.dirname(plan_dir))
        FileUtils.mv(inbox, plan_dir)
        File.write(File.join(plan_dir, "brainstorm.md"), "## Requirements\n- x\n<!-- COMPLETE -->\n")

        plan_md = File.join(plan_dir, "plan.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = plan_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = <<~MD
          ## Overview
          test

          ## Implementation Units
          - U1: foo
          <!-- COMPLETE -->
        MD
        capture_io { Hive::Commands::Run.new(plan_dir).call }
        assert_equal :complete, Hive::Markers.current(plan_md).name
        events = File.readlines(File.join(plan_dir, "events.jsonl"), chomp: true).map { |line| JSON.parse(line) }
        event_types = events.map { |event| event.fetch("event_type") }
        assert_includes event_types, "round_complete",
                        "plan stage must emit round_complete on COMPLETE markers (symmetry with brainstorm)"
        assert_operator event_types.index("stage_enter"), :<, event_types.index("round_complete")
        assert_operator event_types.index("round_complete"), :<, event_types.index("stage_exit")
        assert_equal "3-plan", events.first.fetch("stage")
      end
    end
  end

  def test_plan_stage_waiting_emits_round_waiting
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io do
          Hive::Commands::Init.new(dir).call
          Hive::Commands::New.new(File.basename(dir), "plan stage waiting").call
        end
        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(inbox)
        plan_dir = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(File.dirname(plan_dir))
        FileUtils.mv(inbox, plan_dir)
        File.write(File.join(plan_dir, "brainstorm.md"), "## Requirements\n- x\n<!-- COMPLETE -->\n")

        plan_md = File.join(plan_dir, "plan.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = plan_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Overview\nstub\n<!-- WAITING -->\n"
        capture_io { Hive::Commands::Run.new(plan_dir).call }
        assert_equal :waiting, Hive::Markers.current(plan_md).name
        events = File.readlines(File.join(plan_dir, "events.jsonl"), chomp: true).map { |line| JSON.parse(line) }
        event_types = events.map { |event| event.fetch("event_type") }
        assert_includes event_types, "round_waiting",
                        "plan stage must emit round_waiting on WAITING markers (symmetry with brainstorm)"
      end
    end
  end
end
