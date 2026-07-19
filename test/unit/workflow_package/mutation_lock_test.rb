require "test_helper"
require "hive/workflow_package/mutation_lock"

class WorkflowPackageMutationLockTest < Minitest::Test
  def test_yielded_io_failure_is_not_reclassified_as_lock_contention
    Dir.mktmpdir("hive-mutation-lock") do |dir|
      error = assert_raises(Errno::ENOSPC) do
        Hive::WorkflowPackage::MutationLock.with_lock(dir) { raise Errno::ENOSPC }
      end

      assert_match(/No space left/, error.message)
    end
  end

  def test_lock_acquisition_failure_remains_a_concurrent_run_error
    Dir.mktmpdir("hive-mutation-lock") do |dir|
      parent = File.join(dir, "not-a-directory")
      File.write(parent, "occupied")

      error = assert_raises(Hive::ConcurrentRunError) do
        Hive::WorkflowPackage::MutationLock.with_lock(File.join(parent, "workflows")) { flunk }
      end

      assert_match(/mutation lock failed/, error.message)
    end
  end
end
