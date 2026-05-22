require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/init"
require "hive/commands/run"
require "hive/rebase"
require "hive/stages/execute"

class RunManualSteeringTest < Minitest::Test
  include HiveTestHelper

  def test_manual_steering_marker_skips_rebase_and_stage_runner
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        folder = seed_manual_steered_execute_task(dir)

        rebase_called = false
        runner_called = false
        with_stubbed_singleton_method(Hive::Rebase, :perform, proc { |_task, _cfg|
          rebase_called = true
          raise "rebase should not run for MANUAL_STEERING"
        }) do
          with_stubbed_singleton_method(Hive::Stages::Execute, :run!, proc { |_task, _cfg|
            runner_called = true
            raise "stage runner should not run for MANUAL_STEERING"
          }) do
            out, _err, status = with_captured_exit { Hive::Commands::Run.new(folder, json: true).call }

            assert_equal Hive::ExitCodes::SUCCESS, status
            refute rebase_called, "manual steering must skip the auto-rebase pre-step"
            refute runner_called, "manual steering must not spawn the stage runner"

            payload = JSON.parse(out)
            assert_equal "manual_steering", payload["marker"]
            assert_nil payload["commit_action"]
            assert_equal({ "kind" => Hive::Schemas::NextActionKind::NO_OP, "reason" => "manual_steering" },
                         payload["next_action"])
            assert_equal false, payload.fetch("rebase").fetch("attempted")
            assert_equal "manual_steering", payload.fetch("rebase").fetch("reason")
            assert_run_schema_valid(payload)
          end
        end
      end
    end
  end

  private

  def seed_manual_steered_execute_task(dir)
    slug = "manual-steered-260520-aaaa"
    folder = File.join(dir, ".hive-state", "stages", "4-execute", slug)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "plan.md"), "# Plan\n")
    File.write(File.join(folder, "task.md"), "# Task\n<!-- MANUAL_STEERING agent=codex -->\n")
    folder
  end

  def assert_run_schema_valid(payload)
    schema = JSON.parse(File.read(Hive::Schemas.schema_path("hive-run")))
    schemer = JSONSchemer.schema(schema)
    assert schemer.valid?(payload),
           "hive-run payload must validate: #{schemer.validate(payload).map { |error| error['error'] }.inspect}"
  end

  def with_stubbed_singleton_method(receiver, name, callable)
    singleton = receiver.singleton_class
    backup = :"__manual_steering_original_#{name}"
    singleton.alias_method(backup, name)
    receiver.define_singleton_method(name, &callable)
    yield
  ensure
    if singleton&.method_defined?(backup)
      singleton.alias_method(name, backup)
      singleton.remove_method(backup)
    end
  end
end
