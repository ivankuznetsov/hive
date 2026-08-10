require "test_helper"
require "hive/daemon/activation_lock"

class DaemonActivationLockTest < Minitest::Test
  include HiveTestHelper

  class FailingUnlockHandle
    def flock(*)
      raise IOError, "synthetic unlock failure"
    end

    def close = true
  end

  def test_serializes_profile_activation_on_one_stable_inode
    with_tmp_dir do |dir|
      first = Hive::Daemon::ActivationLock.new(
        hive_home: dir, timeout_sec: 0
      )
      contender = Hive::Daemon::ActivationLock.new(
        hive_home: dir, timeout_sec: 0
      )

      assert_same first, first.acquire!
      error = assert_raises(Hive::ConcurrentRunError) do
        contender.acquire!
      end
      assert_match(/activation lock remained busy/, error.message)
      assert_equal first.path, error.lock_path
      assert first.release!
      assert_same contender, contender.acquire!
      assert contender.release!
      assert File.file?(first.path),
             "the stable lock inode must never be unlinked"
    end
  end

  def test_reentrant_acquire_and_synchronize_release_once
    with_tmp_dir do |dir|
      lock = Hive::Daemon::ActivationLock.new(
        hive_home: dir, timeout_sec: 0
      )

      lock.synchronize do
        lock.synchronize do
          assert_same lock, lock.acquire!
        end
        contender = Hive::Daemon::ActivationLock.new(
          hive_home: dir, timeout_sec: 0
        )
        assert_raises(Hive::ConcurrentRunError) do
          contender.acquire!
        end
      end

      refute lock.release!
    end
  end

  def test_busy_lock_waits_until_a_nonzero_timeout
    with_tmp_dir do |dir|
      holder = Hive::Daemon::ActivationLock.new(
        hive_home: dir, timeout_sec: 0
      )
      holder.acquire!
      contender = Hive::Daemon::ActivationLock.new(
        hive_home: dir, timeout_sec: 0.001
      )

      error = assert_raises(Hive::ConcurrentRunError) do
        contender.acquire!
      end

      assert_match(/0.001s/, error.message)
    ensure
      holder&.release!
    end
  end

  def test_release_wraps_lock_handle_failures
    lock = Hive::Daemon::ActivationLock.new(
      hive_home: "/tmp/hive-activation-release-test",
      timeout_sec: 0
    )
    lock.instance_variable_set(:@handle, FailingUnlockHandle.new)

    error = assert_raises(Hive::ConfigError) { lock.release! }

    assert_match(/could not be released/, error.message)
    assert_match(/synthetic unlock failure/, error.message)
    assert_nil lock.instance_variable_get(:@handle)
  end

  def test_rejects_a_symlinked_lock_path
    with_tmp_dir do |dir|
      target = File.join(dir, "target")
      File.binwrite(target, "")
      File.symlink(target, File.join(
        dir, Hive::Daemon::ActivationLock::LOCK_NAME
      ))

      error = assert_raises(Hive::ConfigError) do
        Hive::Daemon::ActivationLock.new(
          hive_home: dir, timeout_sec: 0
        ).acquire!
      end

      assert_match(/activation lock is unavailable|lock path is unsafe/,
                   error.message)
    end
  end

  def test_rejects_a_hardlink_without_changing_the_target_mode
    with_tmp_dir do |dir|
      target = File.join(dir, "target")
      lock_path = File.join(
        dir, Hive::Daemon::ActivationLock::LOCK_NAME
      )
      File.binwrite(target, "")
      File.chmod(0o644, target)
      File.link(target, lock_path)

      assert_raises(Hive::ConfigError) do
        Hive::Daemon::ActivationLock.new(
          hive_home: dir, timeout_sec: 0
        ).acquire!
      end

      assert_equal 0o644, File.stat(target).mode & 0o777
      assert_equal 2, File.stat(target).nlink
    end
  end

  def test_rejects_a_group_or_world_writable_lock_directory
    with_tmp_dir do |dir|
      File.chmod(0o777, dir)

      error = assert_raises(Hive::ConfigError) do
        Hive::Daemon::ActivationLock.new(
          hive_home: dir, timeout_sec: 0
        ).acquire!
      end

      assert_match(/lock directory is unsafe/, error.message)
    ensure
      File.chmod(0o700, dir) if dir && File.exist?(dir)
    end
  end
end
