require "test_helper"
require "hive/one_shot/runner"

class OneShotRunnerTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 9, 25, 11, 0, 0)

  class Dispatcher
    attr_reader :calls

    def initialize(error: nil)
      @error = error
      @calls = []
    end

    def run_one_shot(**options)
      @calls << [ :run, options ]
      raise @error if @error

      { ran: [ { "id" => "a", "action" => "run", "outcome" => "completed" } ],
        items: [], safe_to_stop: true }
    end

    def observe_one_shot(**options)
      @calls << [ :observe, options ]
      { ran: [], items: [], safe_to_stop: true }
    end

    def one_shot_ran
      [ { "id" => "a", "action" => "run", "outcome" => "failed" } ]
    end
  end

  def test_runs_one_admission_and_captures_result
    dispatcher = Dispatcher.new
    runner = Hive::OneShot::Runner.new(
      dispatcher: dispatcher, project: "hive", clock: -> { NOW }, sleeper: ->(_) { }
    )

    result = runner.call

    assert_equal :run, dispatcher.calls.fetch(0).fetch(0)
    assert_equal "completed", result.fetch(:ran).fetch(0).fetch("outcome")
    assert_equal result.fetch(:ran), runner.ran
  end

  def test_dry_run_only_observes
    dispatcher = Dispatcher.new
    runner = Hive::OneShot::Runner.new(
      dispatcher: dispatcher, project: "hive", dry_run: true, clock: -> { NOW }
    )

    assert_empty runner.call.fetch(:ran)
    assert_equal :observe, dispatcher.calls.fetch(0).fetch(0)
  end

  def test_failure_preserves_dispatcher_run_evidence
    dispatcher = Dispatcher.new(error: RuntimeError.new("failed"))
    runner = Hive::OneShot::Runner.new(
      dispatcher: dispatcher, project: "hive", clock: -> { NOW }
    )

    assert_raises(RuntimeError) { runner.call }
    assert_equal "failed", runner.ran.fetch(0).fetch("outcome")
  end

  def test_default_clock_and_sleeper_are_callable
    runner = Hive::OneShot::Runner.new(dispatcher: Dispatcher.new, project: "hive")

    assert_instance_of Time, runner.instance_variable_get(:@clock).call
    assert_equal 0, runner.instance_variable_get(:@sleeper).call(0)
  end

  def test_build_wires_project_scoped_scheduler_dependencies
    with_tmp_global_config do |home|
      with_tmp_dir do |dir|
        state = File.join(dir, ".hive-state")
        FileUtils.mkdir_p(state)
        entry = {
          "name" => "demo", "path" => dir, "hive_state_path" => state,
          "project_id" => "demo-id", "registration_id" => "demo-registration"
        }
        runner = Hive::OneShot::Runner.build(entry: entry, hive_home: home, dry_run: true)
        assert_instance_of Time, runner.instance_variable_get(:@clock).call
        dispatcher = runner.instance_variable_get(:@dispatcher)
        controller = dispatcher.instance_variable_get(:@controller)
        assert_equal :ok,
                     controller.can_dispatch?(project: "demo", slug: "task", now: NOW)

        patrol_fix = dispatcher.instance_variable_get(:@patrol_fix_admission_scheduler)
        assert_equal [ "demo" ], patrol_fix.send(:project_sources).map(&:project)
        capacity = patrol_fix.instance_variable_get(:@capacity_available)
        source = Struct.new(:project).new("demo")
        assert capacity.call(source: source, now: NOW)

        runtime = dispatcher.instance_variable_get(:@module_runtime)
        assert_equal :idle, runtime.tick(now: NOW, projects: [ "demo" ]).fetch(0).fetch(:status)

      ensure
        runner&.close
      end
    end
  end
end
