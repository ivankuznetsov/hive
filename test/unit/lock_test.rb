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

  def test_acquire_task_lock_raises_after_repeated_stale_collisions
    with_tmp_dir do |dir|
      lock_path = File.join(dir, ".lock")
      File.write(lock_path, { "pid" => Process.pid }.to_yaml)
      attempts = 0
      original_open = File.method(:open)

      with_replaced_singleton_method(Hive::Lock, :stale_lock?, ->(_path) { true }) do
        with_replaced_singleton_method(File, :delete, ->(_path) { }) do
          with_replaced_singleton_method(File, :open, lambda { |path, *args, &block|
            if path == lock_path && (args.first & File::EXCL) != 0
              attempts += 1
              raise Errno::EEXIST
            end

            original_open.call(path, *args, &block)
          }) do
            error = assert_raises(Hive::ConcurrentRunError) { Hive::Lock.acquire_task_lock(dir) }
            assert_match(/another hive run is active/, error.message)
            assert_equal lock_path, error.lock_path
            assert_equal 3, attempts
          end
        end
      end
    end
  end

  def test_update_task_lock_removes_tempfile_when_rename_fails
    with_tmp_dir do |dir|
      lock_path = File.join(dir, ".lock")
      File.write(lock_path, { "pid" => Process.pid }.to_yaml)
      renamed_tmp = nil
      original_rename = File.method(:rename)

      with_replaced_singleton_method(File, :rename, lambda { |src, dest|
        if dest == lock_path
          renamed_tmp = src
          raise Errno::EACCES, "rename blocked"
        end

        original_rename.call(src, dest)
      }) do
        assert_raises(Errno::EACCES) { Hive::Lock.update_task_lock(dir, owner: "test") }
      end

      refute_nil renamed_tmp
      refute File.exist?(renamed_tmp), "failed update must remove its temporary lock file"
    end
  end

  def test_commit_lock_times_out_when_existing_lock_never_releases
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(dir)
      lock_path = File.join(dir, ".commit-lock")
      reader, writer = IO.pipe
      child = fork do
        reader.close
        File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |f|
          f.flock(File::LOCK_EX)
          writer.write("locked\n")
          writer.close
          sleep 10
        end
      end
      writer.close
      assert_equal "locked\n", reader.gets
      reader.close

      base = Time.at(0)
      times = [ base, base + Hive::Lock::COMMIT_LOCK_TIMEOUT_SEC + 1 ]
      error = with_replaced_singleton_method(Time, :now, -> { times.shift || base + 31 }) do
        assert_raises(Hive::ConcurrentRunError) do
          Hive::Lock.with_commit_lock(dir) { flunk "lock should not be acquired" }
        end
      end

      assert_match(/held longer than 30s/, error.message)
      assert_equal lock_path, error.lock_path
    ensure
      Process.kill("KILL", child) if child
      Process.wait(child) if child
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end
  end

  def test_stale_lock_handles_missing_non_hash_and_bad_pid_payloads
    with_tmp_dir do |dir|
      lock_path = File.join(dir, ".lock")

      assert Hive::Lock.stale_lock?(lock_path)

      File.write(lock_path, [ "not", "a", "hash" ].to_yaml)
      assert Hive::Lock.stale_lock?(lock_path)

      File.write(lock_path, { "pid" => "not-an-integer" }.to_yaml)
      assert Hive::Lock.stale_lock?(lock_path)
    end
  end

  def test_stale_lock_returns_false_when_process_signal_is_forbidden
    with_tmp_dir do |dir|
      lock_path = File.join(dir, ".lock")
      File.write(lock_path, { "pid" => 12_345 }.to_yaml)

      with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::EPERM }) do
        refute Hive::Lock.stale_lock?(lock_path)
      end
    end
  end

  def test_stale_lock_treats_reused_pid_as_stale
    with_tmp_dir do |dir|
      lock_path = File.join(dir, ".lock")
      File.write(lock_path, { "pid" => 12_345, "process_start_time" => "old" }.to_yaml)

      with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { true }) do
        with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { "new" }) do
          assert Hive::Lock.stale_lock?(lock_path)
        end
      end
    end
  end

  def test_proc_stat_start_time_returns_nil_when_proc_stat_has_no_tail
    stat_path = "/proc/12345/stat"
    original_exist = File.method(:exist?)
    original_read = File.method(:read)

    with_replaced_singleton_method(File, :exist?, ->(path) { path == stat_path ? true : original_exist.call(path) }) do
      with_replaced_singleton_method(File, :read, ->(path) { path == stat_path ? "" : original_read.call(path) }) do
        assert_nil Hive::Lock.proc_stat_start_time(12_345)
      end
    end
  end

  def test_proc_stat_start_time_returns_nil_when_proc_stat_read_fails
    stat_path = "/proc/12346/stat"
    original_exist = File.method(:exist?)
    original_read = File.method(:read)

    with_replaced_singleton_method(File, :exist?, ->(path) { path == stat_path ? true : original_exist.call(path) }) do
      with_replaced_singleton_method(File, :read, lambda { |path|
        raise Errno::EACCES if path == stat_path

        original_read.call(path)
      }) do
        assert_nil Hive::Lock.proc_stat_start_time(12_346)
      end
    end
  end

  def test_ps_lstart_start_time_handles_empty_output_value_and_errors
    with_replaced_singleton_method(Hive::Lock, :`, ->(_cmd) { "\n" }) do
      assert_nil Hive::Lock.ps_lstart_start_time(12_345)
    end

    with_replaced_singleton_method(Hive::Lock, :`, ->(_cmd) { "Mon Jan  1 00:00:00 2024\n" }) do
      assert_equal "Mon Jan  1 00:00:00 2024", Hive::Lock.ps_lstart_start_time(12_345)
    end

    with_replaced_singleton_method(Hive::Lock, :`, ->(_cmd) { raise "ps failed" }) do
      assert_nil Hive::Lock.ps_lstart_start_time(12_345)
    end
  end

  def with_replaced_singleton_method(receiver, name, replacement)
    original = receiver.method(name)
    receiver.define_singleton_method(name, &replacement)
    yield
  ensure
    receiver.define_singleton_method(name, original) if original
  end
end
