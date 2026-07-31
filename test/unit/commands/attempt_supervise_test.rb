require "test_helper"
require "hive/commands/attempt_supervise"

class AttemptsCommandSuperviseTest < Minitest::Test
  include HiveTestHelper

  def test_invalid_invocations_and_ready_descriptor_fail_as_usage_or_nil
    assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::AttemptSupervise.from_argv([ "attempt", "--store-root" ])
    end
    assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::AttemptSupervise.from_argv([ "attempt", "--store-root", "/tmp", "--", "true" ])
    end
    error = assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::AttemptSupervise.from_argv([ "attempt", "--", "true" ])
    end
    assert_includes error.message, "unknown attempt supervisor option"

    error = assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::AttemptSupervise.from_argv(
        [ "attempt", "--store-root", "/tmp", "--heartbeat-sec", "not-a-number" ]
      )
    end
    assert_includes error.message, "invalid attempt supervisor invocation"

    command = Hive::Commands::AttemptSupervise.from_argv(
      [ "attempt", "--store-root", "/tmp", "--heartbeat-sec", "1" ]
    )
    refute command.instance_variable_defined?(:@worker_argv)

    command = Hive::Commands::AttemptSupervise.new(
      attempt_id: "attempt", store_root: "/tmp",
      heartbeat_sec: 1, stale_sec: 2, first_heartbeat_timeout_sec: 2,
      timeout_sec: nil, kill_grace_sec: 1
    )
    with_env("HIVE_ATTEMPT_READY_FD" => "not-an-fd") do
      assert_nil command.send(:ready_io_from_env)
      assert_nil command.send(:claim_io_from_env)
    end
  end

  def test_worker_release_descriptor_is_opened_for_reading
    command = Hive::Commands::AttemptSupervise.new(
      attempt_id: "attempt", store_root: "/tmp",
      heartbeat_sec: 1, stale_sec: 2,
      first_heartbeat_timeout_sec: 2,
      timeout_sec: nil, kill_grace_sec: 1
    )
    reader, writer = IO.pipe
    inherited = reader.dup
    reader.close

    with_env(
      "HIVE_ATTEMPT_WORKER_RELEASE_FD" =>
        inherited.fileno.to_s
    ) do
      release_io =
        command.send(:worker_release_io_from_env)
      inherited.autoclose = false
      writer.write("1")
      assert_equal "1", release_io.read(1)
      release_io.close
      inherited = nil
    end
  ensure
    [ reader, writer, inherited ].compact.each do |io|
      io.close unless io.closed?
    end
  end

  def test_present_invalid_worker_release_descriptor_fails_closed
    command = Hive::Commands::AttemptSupervise.new(
      attempt_id: "attempt", store_root: "/tmp",
      heartbeat_sec: 1, stale_sec: 2,
      first_heartbeat_timeout_sec: 2,
      timeout_sec: nil, kill_grace_sec: 1
    )

    with_env(
      "HIVE_ATTEMPT_WORKER_RELEASE_FD" => "-1"
    ) do
      error =
        assert_raises(Hive::Attempts::StoreError) do
          command.send(:worker_release_io_from_env)
        end
      assert_includes error.message, "invalid"
    end
  end
end
