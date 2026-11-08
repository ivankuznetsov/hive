require "test_helper"
require "hive/remote/registry_lock"

class RemoteRegistryLockTest < Minitest::Test
  def test_shared_and_exclusive_acquisition_stop_at_the_deadline
    Dir.mktmpdir do |root|
      path = File.join(root, "lock")
      File.open(path, File::RDWR | File::CREAT, 0o600) do |holder|
        holder.flock(File::LOCK_EX)
        File.open(path, File::RDWR) do |waiter|
          [ File::LOCK_SH, File::LOCK_EX ].each do |mode|
            assert_raises(Hive::ConcurrentRunError) do
              Hive::Remote::RegistryLock.acquire!(waiter, mode, timeout: 0)
            end
          end
        end
      end
    end
  end
end
