require "test_helper"
require "hive/commands/attempt_supervise"

class AttemptsCommandSuperviseTest < Minitest::Test
  include HiveTestHelper

  def test_call_passes_inherited_claim_and_ready_descriptors_to_the_supervisor
    with_tmp_dir do |dir|
      Hive::RuntimeControlPlane::Database.new(path: File.join(dir, "runtime.db")).migrate!
      ready_reader, ready_writer = IO.pipe
      claim_reader, claim_writer = IO.pipe
      claim_writer.write("claim-capability")
      claim_writer.close
      captured = nil
      supervisor = Object.new
      supervisor.define_singleton_method(:run) { 17 }
      construct = ->(**kwargs) { captured = kwargs; supervisor }
      command = Hive::Commands::AttemptSupervise.from_argv([
        "attempt-handoff", "--store-root", dir,
        "--database-path", File.join(dir, "runtime.db"),
        "--heartbeat-sec", "2", "--stale-sec", "9",
        "--first-heartbeat-timeout-sec", "8",
        "--timeout-sec", "20", "--kill-grace-sec", "3"
      ])

      with_env(
        "HIVE_ATTEMPT_READY_FD" => ready_writer.fileno.to_s,
        "HIVE_ATTEMPT_CLAIM_FD" => claim_reader.fileno.to_s
      ) do
        with_replaced_singleton_method(Hive::Attempts::Supervisor, :new, construct) do
          assert_equal 17, command.call
        end
      end

      assert_equal "attempt-handoff", captured.fetch(:attempt_id)
      assert_equal "claim-capability", captured.fetch(:claim_io).read
      captured.fetch(:ready_io).write("ready")
      captured.fetch(:ready_io).flush
      assert_equal "ready", ready_reader.read(5)
      assert_equal [ 2, 9, 8, 20, 3 ], captured.values_at(
        :heartbeat_sec, :stale_sec, :first_heartbeat_timeout_sec,
        :timeout_sec, :kill_grace_sec
      )
      assert captured.fetch(:install_signal_handlers)
      assert_equal dir, captured.fetch(:store).root
    ensure
      # IO.for_fd wraps the inherited descriptors; the original pipe objects
      # retain ownership here so GC cannot later close a reused descriptor.
      captured&.values_at(:ready_io, :claim_io)&.each { |io| io.autoclose = false }
      [ ready_reader, ready_writer, claim_reader, claim_writer ].each do |io|
        io.close if io && !io.closed?
      end
    end
  end

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
        [ "attempt", "--store-root", "/tmp", "--database-path", "/tmp/runtime.db",
          "--heartbeat-sec", "not-a-number" ]
      )
    end
    assert_includes error.message, "invalid attempt supervisor invocation"

    command = Hive::Commands::AttemptSupervise.from_argv(
      [ "attempt", "--store-root", "/tmp", "--database-path", "/tmp/runtime.db",
        "--heartbeat-sec", "1" ]
    )
    refute command.instance_variable_defined?(:@worker_argv)

    command = Hive::Commands::AttemptSupervise.new(
      attempt_id: "attempt", store_root: "/tmp", database_path: "/tmp/runtime.db",
      heartbeat_sec: 1, stale_sec: 2, first_heartbeat_timeout_sec: 2,
      timeout_sec: nil, kill_grace_sec: 1
    )
    with_env("HIVE_ATTEMPT_READY_FD" => "not-an-fd") do
      assert_nil command.send(:ready_io_from_env)
      assert_nil command.send(:claim_io_from_env)
    end
  end
end
