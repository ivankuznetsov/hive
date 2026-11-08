require "test_helper"
require "hive/commands/refactor_patrol_scheduled"

class HiveCommandsRefactorPatrolScheduledTest < Minitest::Test
  include HiveTestHelper

  def with_command(remaining: 1, report: nil, error: nil)
    with_tmp_dir do |root|
      entry = { "name" => "demo", "path" => root, "project_id" => "demo-id",
                "hive_state_path" => File.join(root, ".hive-state") }
      cfg = { "default_workflow" => "coding", "daemon" => { "enabled" => true },
              "refactor_patrol" => { "enabled" => true } }
      calls = []
      producer = Object.new
      producer.define_singleton_method(:claim) do
        calls << :claim
        { "id" => "claim", "analysis_sha" => "a" * 40 }
      end
      producer.define_singleton_method(:release) { |claim_id:| calls << [ :release, claim_id ] }
      producer.define_singleton_method(:complete) { |**| calls << :complete; true }
      budget = Object.new
      budget.define_singleton_method(:remaining_launches) { remaining }
      review = Object.new
      review.define_singleton_method(:call) do
        raise error if error
        report
      end
      path = File.join(entry.fetch("hive_state_path"), "refactor_patrol", "v2", "results",
                       "scheduled-#{'a' * 32}.json")
      command = Hive::Commands::RefactorPatrolScheduled.new(
        "demo", result_file: path, config_loader: ->(*) { cfg },
        producer_factory: ->(*) { producer }, budget_factory: ->(*) { budget },
        command_factory: ->(*) { review }
      )
      with_replaced_singleton_method(Hive::Config, :find_project, ->(*) { entry }) do
        yield command, calls, path, entry, cfg, producer, budget, review
      end
    end
  end

  def test_exhausted_allowance_does_not_claim_or_review
    with_command(remaining: 0) do |command, calls, path|
      capture_io { assert command.call.fetch("ok") }
      assert_empty calls
      assert_equal "discovery_allowance_exhausted", JSON.parse(File.read(path)).fetch("reason")
    end
  end

  def test_incomplete_review_releases_slice_without_advancing_cursor
    with_command(report: { "ok" => true, "review_complete" => false }) do |command, calls, path|
      capture_io { refute command.call.fetch("ok") }
      assert_equal [ :claim, [ :release, "claim" ] ], calls
      refute JSON.parse(File.read(path)).fetch("ok")
    end
  end

  def test_provider_start_failure_releases_slice_for_the_next_attempt
    with_command(error: Errno::ENOENT.new("missing provider")) do |command, calls, _path|
      assert_raises(Errno::ENOENT) { command.call }
      assert_equal [ :claim, [ :release, "claim" ] ], calls
    end
  end

  def test_result_path_is_rejected_before_claiming
    with_command do |command, calls, path|
      command.instance_variable_set(:@result_file, File.join(File.dirname(path), "other.json"))
      assert_raises(Hive::ConfigError) { command.call }
      assert_empty calls
    end
  end

  def test_default_composition_publishes_a_completed_review
    report = { "ok" => true, "review_complete" => true, "last_scanned_sha" => "a" * 40 }
    with_command(report: report) do |_command, calls, path, _entry, cfg, producer, budget, review|
      with_replaced_singleton_method(Hive::Config, :load, ->(*) { cfg }) do
        with_replaced_singleton_method(Hive::Patrol::LaunchBudget, :new, ->(*) { budget }) do
          with_replaced_singleton_method(Hive::RefactorPatrol::ScheduledSliceProducer, :new, ->(*) { producer }) do
            with_replaced_singleton_method(Hive::Commands::RefactorPatrol, :new, ->(*) { review }) do
              capture_io do
                result = Hive::Commands::RefactorPatrolScheduled.new("demo", result_file: path).call
                assert_equal "completed", result.fetch("reason")
              end
            end
          end
        end
      end
      assert_equal [ :claim, :complete ], calls
      assert_equal report, JSON.parse(File.read(path)).fetch("report")
    end
  end

  def test_no_available_slice_emits_success_without_reviewing
    with_command do |command, calls, path, _entry, _cfg, producer|
      producer.define_singleton_method(:claim) { calls << :claim; nil }
      capture_io { assert command.call.fetch("ok") }
      assert_equal [ :claim ], calls
      assert_equal "no_available_slice", JSON.parse(File.read(path)).fetch("reason")
    end
  end

  def test_disabled_project_is_rejected_before_claiming
    with_command do |command, calls, _path, _entry, cfg|
      cfg["refactor_patrol"]["enabled"] = false
      assert_raises(Hive::ConfigError) { command.call }
      assert_empty calls
    end
  end

  def test_unknown_project_is_rejected
    with_replaced_singleton_method(Hive::Config, :find_project, ->(*) { nil }) do
      command = Hive::Commands::RefactorPatrolScheduled.new("missing", result_file: "/tmp/result.json")
      assert_raises(Hive::ConfigError) { command.call }
    end
  end
end
