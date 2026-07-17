require "test_helper"
require "hive/commands/retry"

class CommandsRetryTest < Minitest::Test
  include HiveTestHelper

  FakeRecord = Data.define(:data) do
    def to_h = data
  end

  class FakeCoordinator
    attr_reader :calls

    def initialize
      @calls = []
    end

    %i[manual_retry repair abandon rearm].each do |name|
      define_method(name) do |**kwargs|
        @calls << [ name, kwargs ]
        FakeRecord.new({ "state" => "ready", "retry_count" => 0 })
      end
    end
  end

  def test_manual_retry_routes_through_coordinator_without_audit_metadata
    with_retry_task do |folder|
      coordinator = FakeCoordinator.new
      out, = capture_io do
        Hive::Commands::Retry.new(
          "manual", folder, generation: "7", json: true,
          coordinator_factory: ->(_task, _store) { coordinator }
        ).call
      end

      assert_equal [ [ :manual_retry, { expected_generation: 7 } ] ], coordinator.calls
      payload = JSON.parse(out)
      assert_equal "manual", payload.fetch("action")
      assert_equal "ready", payload.dig("retry", "state")
    end
  end

  def test_reset_alias_is_an_audited_repair
    with_retry_task do |folder|
      coordinator = FakeCoordinator.new
      Hive::Commands::Retry.new(
        "reset", folder, generation: 2, actor: "operator@example.test",
        reason: "credentials repaired",
        coordinator_factory: ->(_task, _store) { coordinator }
      ).call

      assert_equal [ [ :repair, {
        expected_generation: 2,
        actor: "operator@example.test",
        reason: "credentials repaired"
      } ] ], coordinator.calls
    end
  end

  def test_abandon_and_rearm_use_generation_guard_and_audit_fields
    with_retry_task do |folder|
      coordinator = FakeCoordinator.new
      factory = ->(_task, _store) { coordinator }

      Hive::Commands::Retry.new(
        "abandon", folder, generation: 4, actor: "alice", reason: "pause spend",
        coordinator_factory: factory
      ).call
      Hive::Commands::Retry.new(
        "re-arm", folder, generation: 4, actor: "alice", reason: "repair landed",
        coordinator_factory: factory
      ).call

      assert_equal :abandon, coordinator.calls[0][0]
      assert_equal :rearm, coordinator.calls[1][0]
      assert_equal 4, coordinator.calls[1][1].fetch(:expected_generation)
    end
  end

  def test_audited_actions_require_actor_and_reason
    with_retry_task do |folder|
      error = assert_raises(Hive::Error) do
        Hive::Commands::Retry.new("repair", folder, generation: 1, reason: "fixed").call
      end
      assert_match(/--actor is required/, error.message)

      error = assert_raises(Hive::Error) do
        Hive::Commands::Retry.new("abandon", folder, generation: 1, actor: "alice").call
      end
      assert_match(/--reason is required/, error.message)
    end
  end

  def test_generation_must_be_non_negative_integer
    error = assert_raises(Hive::Error) do
      Hive::Commands::Retry.new("manual", "unused", generation: "latest").call
    end
    assert_match(/--generation must be a non-negative integer/, error.message)
  end

  private

  def with_retry_task
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "4-execute", "retry-task-260717-abcd")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "# Retry task\n<!-- EXECUTE_WAITING -->\n")
      yield folder
    end
  end
end
