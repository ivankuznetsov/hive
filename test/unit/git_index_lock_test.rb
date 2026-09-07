require "test_helper"
require "hive/git_index_lock"
require "hive/lock"

class GitIndexLockTest < Minitest::Test
  include HiveTestHelper

  def test_abandoned_empty_lock_is_quarantined_and_git_can_write_again
    with_tmp_git_repo do |root|
      path = File.join(root, ".git", "index.lock")
      File.write(path, "")
      File.utime(Time.now - 120, Time.now - 120, path)
      with_replaced_singleton_method(Hive::GitIndexLock, :no_writers?, ->(_) { true }) do
        Hive::Lock.with_commit_lock(root) { run!("git", "-C", root, "add", "-A") }
      end
      refute File.exist?(path)
      assert_equal 1, Dir.glob("#{path}.hive-stale-*").length
      run!("git", "-C", root, "add", "-A")
    end
  end

  def test_live_writer_recent_nonempty_and_symlink_locks_are_preserved
    with_tmp_git_repo do |root|
      path = File.join(root, ".git", "index.lock")
      File.write(path, "")
      with_replaced_singleton_method(Hive::GitIndexLock, :no_writers?, ->(_) { true }) do
        Hive::GitIndexLock.recover!(root)
        assert File.exist?(path), "recent lock"
        File.write(path, "index bytes")
        File.utime(Time.now - 120, Time.now - 120, path)
        Hive::GitIndexLock.recover!(root)
        assert_equal "index bytes", File.read(path)
      end
      File.write(path, "")
      File.utime(Time.now - 120, Time.now - 120, path)
      with_replaced_singleton_method(Hive::GitIndexLock, :no_writers?, ->(_) { false }) do
        Hive::GitIndexLock.recover!(root)
      end
      assert File.exist?(path), "live writer"
      File.unlink(path)
      File.symlink("index", path)
      Hive::GitIndexLock.recover!(root)
      assert File.symlink?(path)
    end
  end

  def test_writer_probe_fails_closed_for_git_processes_and_probe_errors
    status = Struct.new(:exitstatus) { def success? = exitstatus.zero? }
    [ [ "git\n", "", 0 ], [ "", "denied", 1 ] ].each do |out, err, code|
      with_replaced_singleton_method(Open3, :capture3, ->(*) { [ out, err, status.new(code) ] }) do
        refute Hive::GitIndexLock.no_writers?("/unused")
      end
    end
    [ [ "", "", 1, true ], [ "123", "", 0, false ], [ "", "denied", 1, false ] ].each do |out, err, code, expected|
      probe = ->(tool, *) { tool == "ps" ? [ "ruby\n", "", status.new(0) ] : [ out, err, status.new(code) ] }
      with_replaced_singleton_method(Open3, :capture3, probe) do
        assert_equal expected, Hive::GitIndexLock.no_writers?("/unused")
      end
    end
  end

  def test_recovery_preserves_a_lock_replaced_during_inspection_and_missing_tools
    with_tmp_git_repo do |root|
      path = File.join(root, ".git", "index.lock")
      File.write(path, "")
      File.utime(Time.now - 120, Time.now - 120, path)
      probe = lambda do |_|
        File.rename(path, "#{path}.original")
        File.write(path, "new owner")
        true
      end
      with_replaced_singleton_method(Hive::GitIndexLock, :no_writers?, probe) do
        Hive::GitIndexLock.recover!(root)
      end
      assert_equal "new owner", File.read(path)
      File.write(path, "")
      File.utime(Time.now - 120, Time.now - 120, path)
      with_replaced_singleton_method(Hive::GitIndexLock, :no_writers?, ->(_) { raise Errno::ENOENT, "fuser" }) do
        Hive::GitIndexLock.recover!(root)
      end
      assert File.exist?(path)
    end
  end
end
