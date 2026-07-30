require "test_helper"
require "hive/refactor_patrol/job_store_writer_fence"

class RefactorPatrolJobStoreWriterFenceTest < Minitest::Test
  include HiveTestHelper

  FakeProcess = Struct.new(:alive) do
    def kill(_signal, _pid)
      raise Errno::ESRCH, "gone" unless alive

      true
    end
  end

  def test_missing_or_dead_daemon_is_quiescent
    with_tmp_dir do |dir|
      pid_file = File.join(dir, ".daemon.pid")
      assert writer_fence(pid_file, process: FakeProcess.new(false))
        .assert_quiescent!

      write_pid_file(pid_file)
      assert writer_fence(pid_file, process: FakeProcess.new(false))
        .assert_quiescent!
    end
  end

  def test_live_exact_daemon_blocks_reset
    with_tmp_dir do |dir|
      pid_file = File.join(dir, ".daemon.pid")
      write_pid_file(pid_file)
      fence = writer_fence(pid_file, process: FakeProcess.new(true))

      error = with_replaced_singleton_method(
        Hive::Lock, :process_start_time, ->(*) { "start-71" }
      ) do
        assert_raises(Hive::ConcurrentRunError) do
          fence.assert_quiescent!
        end
      end

      assert_match(/stop the running Hive daemon/, error.message)
      assert_equal 71, error.holder.fetch(:pid)
    end
  end

  def test_unbound_live_pid_and_malformed_payload_fail_closed
    with_tmp_dir do |dir|
      pid_file = File.join(dir, ".daemon.pid")
      write_pid_file(pid_file)
      fence = writer_fence(pid_file, process: FakeProcess.new(true))

      error = with_replaced_singleton_method(
        Hive::Lock, :process_start_time, ->(*) { "different-start" }
      ) do
        assert_raises(Hive::ConcurrentRunError) do
          fence.assert_quiescent!
        end
      end
      assert_match(/cannot verify the live Hive daemon/, error.message)

      File.write(pid_file, "--- {}\n")
      malformed = assert_raises(Hive::ConcurrentRunError) do
        fence.assert_quiescent!
      end
      assert_match(/cannot verify the Hive daemon writer fence/,
                   malformed.message)
    end
  end

  private

  def writer_fence(pid_file, process:)
    Hive::RefactorPatrol::JobStoreWriterFence.new(
      pid_file: pid_file,
      process: process
    )
  end

  def write_pid_file(path)
    File.write(
      path,
      {
        "pid" => 71,
        "process_start_time" => "start-71"
      }.to_yaml
    )
  end
end
