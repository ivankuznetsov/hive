require "test_helper"
require "weakref"
require "hive/runtime_control_plane"

class RuntimeControlPlaneProcessGuardTest < Minitest::Test
  include HiveTestHelper

  def test_connected_database_stays_registered_without_an_external_owner
    with_tmp_dir do |root|
      database = database_at(File.join(root, "unowned.sqlite3"))
      reference = WeakRef.new(database)
      database = nil
      GC.start

      assert reference.weakref_alive?
      registered = reference.__getobj__
      Hive::RuntimeControlPlane::ProcessGuard.disconnect_all!
      assert registered.disconnected?
    ensure
      Hive::RuntimeControlPlane::ProcessGuard.after_fork_parent!
      registered&.disconnect
    end
  end

  def test_fork_request_from_owning_checkout_fails_without_deadlock
    with_database do |database|
      error = assert_raises(Hive::RuntimeControlPlane::ForkUnsafe) do
        database.read { Hive::RuntimeControlPlane::ProcessGuard.before_fork! }
      end

      assert_equal :fork_during_transaction, error.code
      assert_equal 1, database.read { |db| db[:installations].count }
    end
  end

  def test_active_transaction_rejects_fork_and_guard_recovers
    with_database do |database|
      entered = Queue.new
      release = Queue.new
      worker = Thread.new do
        database.transaction do
          entered << true
          release.pop
        end
      end
      entered.pop

      assert_raises(Hive::RuntimeControlPlane::ForkUnsafe) do
        Hive::RuntimeControlPlane::ProcessGuard.before_fork!
      end
      release << true
      worker.join
      assert_equal 1, database.read { |db| db[:installations].count }
    end
  end

  def test_barrier_waits_for_reads_blocks_new_checkouts_and_disconnects_every_database
    with_tmp_dir do |root|
      first = database_at(File.join(root, "first.sqlite3"))
      second = database_at(File.join(root, "second.sqlite3"))
      entered = Queue.new
      release = Queue.new
      reader = Thread.new do
        first.read do
          entered << true
          release.pop
        end
      end
      entered.pop

      barrier_entered = Queue.new
      barrier_release = Queue.new
      barrier = Thread.new do
        Hive::RuntimeControlPlane::ProcessGuard.before_fork!
        barrier_entered << true
        barrier_release.pop
        Hive::RuntimeControlPlane::ProcessGuard.after_fork_parent!
      end
      wait_for_fork_barrier
      blocked_checkout_entered = Queue.new
      blocked = Thread.new do
        second.read { blocked_checkout_entered << true }
      end
      assert blocked_checkout_entered.empty?

      release << true
      reader.join
      barrier_entered.pop
      assert first.disconnected?
      assert second.disconnected?
      assert blocked_checkout_entered.empty?

      barrier_release << true
      barrier.join
      blocked.join
      assert_equal true, blocked_checkout_entered.pop
    ensure
      Hive::RuntimeControlPlane::ProcessGuard.after_fork_parent!
      first&.disconnect
      second&.disconnect
    end
  end

  def test_concurrent_fork_barriers_serialize_and_keep_new_checkouts_blocked
    with_database do |database|
      first_entered = Queue.new
      release_first = Queue.new
      first = Thread.new do
        Hive::RuntimeControlPlane::ProcessGuard.before_fork!
        first_entered << true
        release_first.pop
        Hive::RuntimeControlPlane::ProcessGuard.after_fork_parent!
      end
      first_entered.pop

      second_entered = Queue.new
      release_second = Queue.new
      second = Thread.new do
        Hive::RuntimeControlPlane::ProcessGuard.before_fork!
        second_entered << true
        release_second.pop
        Hive::RuntimeControlPlane::ProcessGuard.after_fork_parent!
      end
      guard_state = Hive::RuntimeControlPlane::ProcessGuard.send(:state)
      Timeout.timeout(1) do
        loop do
          waiting = guard_state[:mutex].synchronize do
            guard_state[:fork_waiters] == 1
          end
          break if waiting

          Thread.pass
        end
      end
      checkout_started = Queue.new
      checkout_entered = Queue.new
      checkout = Thread.new do
        checkout_started << true
        database.read { checkout_entered << true }
      end
      checkout_started.pop
      assert second_entered.empty?
      assert checkout_entered.empty?

      release_first << true
      first.join
      assert_equal true, second_entered.pop
      assert checkout_entered.empty?

      release_second << true
      second.join
      checkout.join
      assert_equal true, checkout_entered.pop
    ensure
      release_first << true if first&.alive?
      release_second << true if second&.alive?
      first&.join
      second&.join
      checkout&.join
    end
  end

  def test_real_fork_waits_for_temporary_diagnostics_connection_and_inherits_no_descriptor
    with_database do |database|
      entered = Queue.new
      release = Queue.new
      original = database.method(:inspect_database)
      database.define_singleton_method(:inspect_database) do |&block|
        original.call do |connection|
          entered << true
          release.pop
          block.call(connection)
        end
      end
      diagnosis = nil
      reader = Thread.new { diagnosis = database.diagnostics }
      entered.pop

      read_pipe, write_pipe = IO.pipe
      fork_complete = Queue.new
      forker = Thread.new do
        child = Hive::RuntimeControlPlane::ProcessGuard.fork do
          read_pipe.close
          targets = Dir.children("/proc/self/fd").filter_map do |name|
            File.readlink("/proc/self/fd/#{name}")
          rescue Errno::ENOENT
            nil
          end
          write_pipe.write(Marshal.dump(targets.grep(/runtime\.sqlite3/)))
          write_pipe.close
          exit! 0
        end
        fork_complete << child
      end
      wait_for_fork_barrier
      assert fork_complete.empty?

      release << true
      reader.join
      child = fork_complete.pop
      write_pipe.close
      inherited = Marshal.load(read_pipe.read)
      Process.wait(child)
      forker.join
      assert diagnosis.ok?
      assert_empty inherited
    ensure
      read_pipe&.close unless read_pipe&.closed?
      write_pipe&.close unless write_pipe&.closed?
    end
  end

  def test_real_fork_child_inherits_no_sqlite_descriptors_from_mixed_open_databases
    with_tmp_dir do |root|
      first = database_at(File.join(root, "first.sqlite3"))
      second = database_at(File.join(root, "second.sqlite3"))
      first.read { |db| db[:installations].count }
      second.read { |db| db[:installations].count }
      reader, writer = IO.pipe

      child = Hive::RuntimeControlPlane::ProcessGuard.fork do
        reader.close
        targets = Dir.children("/proc/self/fd").filter_map do |name|
          File.readlink("/proc/self/fd/#{name}")
        rescue Errno::ENOENT
          nil
        end
        inherited = targets.grep(/(?:first|second)\.sqlite3/)
        writer.write(Hive::RuntimeControlPlane::Codec.dump_json(inherited))
        writer.close
        exit! 0
      end
      writer.close
      inherited = Hive::RuntimeControlPlane::Codec.load_json(reader.read)
      Process.wait(child)

      assert_empty inherited
      assert first.disconnected?
      assert second.disconnected?
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
      first&.disconnect
      second&.disconnect
    end
  end

  def test_spawned_agent_process_inherits_no_sqlite_descriptors
    with_tmp_dir do |root|
      first = database_at(File.join(root, "first.sqlite3"))
      second = database_at(File.join(root, "second.sqlite3"))
      first.read { |db| db[:installations].count }
      second.read { |db| db[:installations].count }
      reader, writer = IO.pipe
      script = <<~'RUBY'
        targets = Dir.children("/proc/self/fd").filter_map do |name|
          File.readlink("/proc/self/fd/#{name}")
        rescue Errno::ENOENT
          nil
        end
        STDOUT.write(Marshal.dump(targets.grep(/(?:first|second)\.sqlite3/)))
      RUBY

      child = Process.spawn(RbConfig.ruby, "-e", script, out: writer, close_others: true)
      writer.close
      inherited = Marshal.load(reader.read)
      Process.wait(child)

      assert_empty inherited
      refute first.disconnected?, "spawn must not disconnect the supervisor"
      refute second.disconnected?, "spawn must not disconnect the supervisor"
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
      first&.disconnect
      second&.disconnect
    end
  end

  def test_self_exec_child_inherits_no_sqlite_descriptors
    with_tmp_dir do |root|
      first = database_at(File.join(root, "first.sqlite3"))
      second = database_at(File.join(root, "second.sqlite3"))
      first.read { |db| db[:installations].count }
      second.read { |db| db[:installations].count }
      reader, writer = IO.pipe
      script = <<~'RUBY'
        targets = Dir.children("/proc/self/fd").filter_map do |name|
          File.readlink("/proc/self/fd/#{name}")
        rescue Errno::ENOENT
          nil
        end
        STDOUT.write(Marshal.dump(targets.grep(/(?:first|second)\.sqlite3/)))
      RUBY

      child = Hive::RuntimeControlPlane::ProcessGuard.fork do
        reader.close
        Hive::RuntimeControlPlane::ProcessGuard.exec(
          RbConfig.ruby, "-e", script, out: writer, close_others: true
        )
      end
      writer.close
      inherited = Marshal.load(reader.read)
      Process.wait(child)

      assert_empty inherited
      assert first.disconnected?
      assert second.disconnected?
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
      first&.disconnect
      second&.disconnect
    end
  end

  def test_daemonized_child_inherits_no_sqlite_descriptors
    with_tmp_dir do |root|
      reader, writer = IO.pipe
      child = Hive::RuntimeControlPlane::ProcessGuard.fork do
        reader.close
        first = database_at(File.join(root, "first.sqlite3"))
        second = database_at(File.join(root, "second.sqlite3"))
        first.read { |db| db[:installations].count }
        second.read { |db| db[:installations].count }

        Hive::RuntimeControlPlane::ProcessGuard.daemonize(true, true)
        targets = Dir.children("/proc/self/fd").filter_map do |name|
          File.readlink("/proc/self/fd/#{name}")
        rescue Errno::ENOENT
          nil
        end
        writer.write(Marshal.dump(targets.grep(/(?:first|second)\.sqlite3/)))
        writer.close
        exit! 0
      end
      writer.close
      Process.wait(child)
      inherited = Marshal.load(Timeout.timeout(5) { reader.read })

      assert_empty inherited
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end
  end

  def test_failed_process_creation_releases_the_fork_barrier
    original_fork = Process.method(:fork)
    original_daemon = Process.method(:daemon)
    Process.define_singleton_method(:fork) { raise Errno::EAGAIN, "fork unavailable" }
    assert_raises(Errno::EAGAIN) do
      Hive::RuntimeControlPlane::ProcessGuard.fork { flunk "child must not run" }
    end
    Process.define_singleton_method(:daemon) { |*| raise Errno::EPERM, "daemon unavailable" }
    assert_raises(Errno::EPERM) do
      Hive::RuntimeControlPlane::ProcessGuard.daemonize(true, true)
    end

    state = Hive::RuntimeControlPlane::ProcessGuard.send(:state)
    refute state[:mutex].synchronize { state[:forking] }
  ensure
    Process.define_singleton_method(:fork, original_fork) if original_fork
    Process.define_singleton_method(:daemon, original_daemon) if original_daemon
  end

  private

  def wait_for_fork_barrier
    guard_state = Hive::RuntimeControlPlane::ProcessGuard.send(:state)
    Timeout.timeout(1) do
      loop do
        break if guard_state[:mutex].synchronize { guard_state[:forking] }

        Thread.pass
      end
    end
  end

  def with_database
    with_tmp_dir do |root|
      database = database_at(File.join(root, "runtime.sqlite3"))
      yield database
    ensure
      database&.disconnect
    end
  end

  def database_at(path)
    Hive::RuntimeControlPlane::Database.new(path: path).migrate!
  end
end
