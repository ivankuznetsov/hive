require "test_helper"
require "hive/commands/attempt_supervise"

class AttemptsCommandSuperviseTest < Minitest::Test
  include HiveTestHelper

  def test_invalid_invocations_and_ready_descriptor_fail_as_usage_or_nil
    assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::AttemptSupervise.from_argv([ "attempt", "--store-root" ])
    end
    assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::AttemptSupervise.from_argv([ "attempt", "--store-root", "/tmp" ])
    end
    error = assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::AttemptSupervise.from_argv([ "attempt", "--", "true" ])
    end
    assert_includes error.message, "invalid attempt supervisor invocation"

    command = Hive::Commands::AttemptSupervise.new(
      attempt_id: "attempt", store_root: "/tmp", worker_argv: [ "true" ],
      heartbeat_sec: 1, stale_sec: 2, first_heartbeat_timeout_sec: 2,
      timeout_sec: nil, kill_grace_sec: 1
    )
    with_env("HIVE_ATTEMPT_READY_FD" => "not-an-fd") do
      assert_nil command.send(:ready_io_from_env)
    end
  end
end
