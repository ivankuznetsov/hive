require "test_helper"
require "hive/lock"

class LockTest < Minitest::Test
  include HiveTestHelper

  def test_with_task_lock_creates_and_removes
    with_tmp_dir do |dir|
      Hive::Lock.with_task_lock(dir, slug: "x") do
        assert File.exist?(File.join(dir, ".lock"))
      end
      refute File.exist?(File.join(dir, ".lock")), "lock should be released after block"
    end
  end

  def test_with_task_lock_releases_on_exception
    with_tmp_dir do |dir|
      assert_raises(RuntimeError) do
        Hive::Lock.with_task_lock(dir) { raise "boom" }
      end
      refute File.exist?(File.join(dir, ".lock"))
    end
  end

  def test_concurrent_run_with_live_pid_raises
    with_tmp_dir do |dir|
      # Fork a child that holds the PID alive.
      reader, writer = IO.pipe
      child = fork do
        reader.close
        writer.write("ready\n")
        writer.close
        sleep 5
      end
      writer.close
      assert_equal "ready\n", reader.gets
      reader.close

      Hive::Lock.acquire_task_lock(dir, "pid" => child, "process_start_time" => Hive::Lock.process_start_time(child))

      # Now a different process trying to acquire should see live PID and raise.
      assert_raises(Hive::ConcurrentRunError) { Hive::Lock.acquire_task_lock(dir) }
    ensure
      if child
        Process.kill("KILL", child)
        Process.wait(child)
      end
      Hive::Lock.release_task_lock(dir)
    end
  end

  def test_stale_lock_with_dead_pid_is_replaced
    with_tmp_dir do |dir|
      # Create lock file with a dead PID directly on disk.
      bogus = { "pid" => 999_999, "started_at" => Time.now.utc.iso8601, "process_start_time" => "0" }
      File.write(File.join(dir, ".lock"), bogus.to_yaml)
      data = Hive::Lock.acquire_task_lock(dir)
      assert_equal Process.pid, data["pid"]
    ensure
      Hive::Lock.release_task_lock(dir)
    end
  end

  def test_invalid_yaml_lock_treated_as_stale
    with_tmp_dir do |dir|
      File.write(File.join(dir, ".lock"), "::not valid yaml::")
      data = Hive::Lock.acquire_task_lock(dir)
      assert_equal Process.pid, data["pid"]
    ensure
      Hive::Lock.release_task_lock(dir)
    end
  end

  def test_commit_lock_serializes
    with_tmp_dir do |dir|
      results = []
      Hive::Lock.with_commit_lock(dir) { results << :first }
      Hive::Lock.with_commit_lock(dir) { results << :second }
      assert_equal %i[first second], results
    end
  end

  def test_commit_lock_blocks_other_process
    with_tmp_dir do |dir|
      reader, writer = IO.pipe
      child = fork do
        reader.close
        Hive::Lock.with_commit_lock(dir) do
          writer.write("locked\n")
          sleep 0.5
        end
        writer.close
      end
      writer.close
      assert_equal "locked\n", reader.gets, "child should signal lock acquired"

      t0 = Time.now
      Hive::Lock.with_commit_lock(dir) { :ok }
      elapsed = Time.now - t0
      assert_operator elapsed, :>=, 0.2, "second acquire should wait for child to release"
      reader.close
    ensure
      Process.wait(child) if child
    end
  end
end
