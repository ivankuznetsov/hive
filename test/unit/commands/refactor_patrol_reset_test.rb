require "test_helper"
require "hive/cli"
require "hive/commands/refactor_patrol_reset"
require "timeout"

class RefactorPatrolResetCommandTest < Minitest::Test
  include HiveTestHelper

  class FakeQuiescence
    attr_reader :calls

    def initialize(running: false, timeline: nil)
      @running = running
      @calls = []
      @timeline = timeline
    end

    def quiesce!
      @calls << :quiesce
      @timeline&.push(:quiesce)
      @running
    end

    def restart!
      @calls << :restart
      @timeline&.push(:restart)
      true
    end
  end

  class FakeActivationLock
    attr_reader :calls

    def initialize(entered: nil, timeline: nil)
      @calls = []
      @entered = entered
      @timeline = timeline
    end

    def synchronize
      @calls << :enter_activation
      @timeline&.push(:enter_activation)
      @entered&.push(true)
      yield
    ensure
      @calls << :leave_activation
      @timeline&.push(:leave_activation)
    end
  end

  class FakePatrolFence
    attr_reader :calls

    def initialize(timeline: nil)
      @calls = []
      @timeline = timeline
    end

    def call(entry)
      @calls << [ :enter_patrol, entry.fetch("project_id") ]
      @timeline&.push(:enter_patrol)
      yield
    ensure
      @calls << [ :leave_patrol, entry.fetch("project_id") ]
      @timeline&.push(:leave_patrol)
    end
  end

  def test_requires_explicit_confirmation_before_daemon_or_storage_effects
    lifecycle = FakeQuiescence.new
    command = Hive::Commands::RefactorPatrolReset.new(
      "demo",
      confirm: false,
      project_resolver: ->(*) { flunk "unconfirmed reset resolved project" },
      resetter: ->(*) { flunk "unconfirmed reset reached storage" },
      daemon_quiescence: lifecycle
    )

    error = assert_raises(Hive::ConfigError) { command.call }

    assert_match(/requires --confirm/, error.message)
    assert_empty lifecycle.calls
  end

  def test_json_confirmation_failure_is_a_typed_error_envelope
    output = StringIO.new
    command = Hive::Commands::RefactorPatrolReset.new(
      "demo",
      confirm: false,
      json: true,
      output: output,
      project_resolver: ->(*) {
        flunk "unconfirmed reset resolved project"
      }
    )

    assert_raises(Hive::ConfigError) { command.call }

    payload = JSON.parse(output.string)
    assert_equal false, payload.fetch("ok")
    assert_equal "confirmation_required",
                 payload.fetch("error_kind")
    assert_equal "demo", payload.fetch("project")
    assert_equal Hive::ExitCodes::CONFIG,
                 payload.fetch("exit_code")
  end

  def test_resets_one_exact_registered_project_and_emits_canonical_json
    with_tmp_dir do |root|
      state = File.join(root, ".custom-state")
      entry = registered_entry(root, state)
      timeline = []
      lifecycle = FakeQuiescence.new(
        running: true, timeline: timeline
      )
      activation_lock = FakeActivationLock.new(
        timeline: timeline
      )
      patrol_fence = FakePatrolFence.new(timeline: timeline)
      output = StringIO.new
      seen = nil
      result = {
        "schema" =>
          Hive::RefactorPatrol::JobStoreFreshStart::STATUS_SCHEMA,
        "schema_version" =>
          Hive::RefactorPatrol::JobStoreFreshStart::STATUS_VERSION,
        "status" => "current",
        "changed" => true,
        "archive_path" => File.join(state, "archive"),
        "receipt_path" => File.join(state, "receipt.json")
      }
      command = Hive::Commands::RefactorPatrolReset.new(
        "demo",
        confirm: true,
        json: true,
        output: output,
        project_resolver: ->(name) {
          assert_equal "demo", name
          entry
        },
        resetter: ->(identity) {
          timeline << :reset
          seen = identity
          result
        },
        daemon_quiescence: lifecycle,
        activation_lock: activation_lock,
        patrol_fence: patrol_fence
      )

      payload = command.call

      assert_equal state, seen.fetch("hive_state_path")
      assert_equal "project-demo", seen.fetch("project_id")
      assert_equal %i[quiesce restart], lifecycle.calls
      assert_equal(
        %i[
          enter_activation quiesce enter_patrol reset
          leave_patrol leave_activation restart
        ],
        timeline
      )
      assert_equal payload, JSON.parse(output.string)
      assert_equal(
        "#{Hive::WorkflowPackage::CanonicalJSON.generate(payload)}\n",
        output.string
      )
      assert_equal "hive-refactor-patrol-jobstore-reset",
                   payload.fetch("schema")
      assert_equal true, payload.fetch("changed")
    end
  end

  def test_restarts_a_previously_running_daemon_when_reset_fails
    with_tmp_dir do |root|
      lifecycle = FakeQuiescence.new(running: true)
      command = Hive::Commands::RefactorPatrolReset.new(
        "demo",
        confirm: true,
        project_resolver: ->(*) {
          registered_entry(root, File.join(root, ".hive-state"))
        },
        resetter: ->(*) { raise IOError, "reset failed" },
        daemon_quiescence: lifecycle,
        activation_lock: FakeActivationLock.new,
        patrol_fence: FakePatrolFence.new
      )

      error = assert_raises(Hive::InternalError) { command.call }

      assert_match(/IOError: reset failed/, error.message)
      assert_equal %i[quiesce restart], lifecycle.calls
    end
  end

  def test_leaves_an_already_stopped_daemon_stopped
    with_tmp_dir do |root|
      lifecycle = FakeQuiescence.new(running: false)
      command = Hive::Commands::RefactorPatrolReset.new(
        "demo",
        confirm: true,
        project_resolver: ->(*) {
          registered_entry(root, File.join(root, ".hive-state"))
        },
        resetter: ->(*) {
          {
            "status" => "fresh",
            "changed" => false,
            "archive_path" => nil,
            "receipt_path" => nil
          }
        },
        daemon_quiescence: lifecycle,
        activation_lock: FakeActivationLock.new,
        patrol_fence: FakePatrolFence.new,
        output: StringIO.new
      )

      command.call

      assert_equal [ :quiesce ], lifecycle.calls
    end
  end

  def test_waits_for_an_in_flight_patrol_effect_before_resetting
    with_tmp_dir do |root|
      state = File.join(root, ".hive-state")
      entry = registered_entry(root, state)
      effect_admitted = Queue.new
      release_effect = Queue.new
      activation_entered = Queue.new
      reset_reached = Queue.new
      effect_thread = Thread.new do
        Hive::Modules::Migration::Patrols.with_migration_lock(
          root, hive_state_path: state, shared: true
        ) do
          effect_admitted.push(true)
          release_effect.pop
        end
      end
      effect_admitted.pop
      command = Hive::Commands::RefactorPatrolReset.new(
        "demo",
        confirm: true,
        output: StringIO.new,
        project_resolver: ->(*) { entry },
        resetter: lambda { |_identity|
          reset_reached.push(true)
          {
            "status" => "fresh",
            "changed" => false,
            "archive_path" => nil,
            "receipt_path" => nil
          }
        },
        daemon_quiescence: FakeQuiescence.new,
        activation_lock:
          FakeActivationLock.new(entered: activation_entered)
      )
      reset_thread = Thread.new { command.call }
      activation_entered.pop

      assert_raises(Timeout::Error) do
        Timeout.timeout(0.1) { reset_reached.pop }
      end

      release_effect.push(true)
      assert Timeout.timeout(2) { reset_reached.pop }
      assert_kind_of Hash, Timeout.timeout(2) {
        reset_thread.value
      }
    ensure
      release_effect&.push(true) if
        effect_thread&.alive?
      effect_thread&.join
      reset_thread&.join if reset_thread&.alive?
    end
  end

  def test_rejects_unknown_and_drifted_registered_projects
    lifecycle = FakeQuiescence.new
    unknown = Hive::Commands::RefactorPatrolReset.new(
      "missing",
      confirm: true,
      project_resolver: ->(*) { nil },
      daemon_quiescence: lifecycle
    )
    error = assert_raises(Hive::ConfigError) { unknown.call }
    assert_match(/unknown project "missing"/, error.message)

    with_tmp_dir do |root|
      drifted = Hive::Commands::RefactorPatrolReset.new(
        "demo",
        confirm: true,
        project_resolver: ->(*) {
          registered_entry(
            root, File.join(root, ".hive-state")
          ).merge("real_path" => File.join(root, "old"))
        },
        daemon_quiescence: lifecycle
      )
      error = assert_raises(Hive::ConfigError) { drifted.call }
      assert_match(/canonical path/, error.message)
    end
    assert_empty lifecycle.calls
  end

  def test_cli_routes_project_confirmation_and_json
    calls = []
    fake = Object.new
    fake.define_singleton_method(:call) { calls << :call }

    with_replaced_singleton_method(
      Hive::Commands::RefactorPatrolReset,
      :new,
      ->(project, confirm:, json:) {
        calls << [ project, confirm, json ]
        fake
      }
    ) do
      Hive::CLI.start([
        "refactor-patrol-reset", "demo", "--confirm", "--json"
      ])
    end

    assert_equal [ [ "demo", true, true ], :call ], calls
    assert Hive::CLI.tasks.key?("refactor_patrol_reset")
    refute Hive::CLI.tasks.key?("refactor_patrol_schema_restore")
    refute Hive::CLI.tasks.key?("refactor_patrol_migrate_installed")
  end

  private

  def registered_entry(root, state)
    {
      "name" => "demo",
      "project_id" => "project-demo",
      "path" => root,
      "real_path" => File.realpath(root),
      "hive_state_path" => state
    }
  end
end
