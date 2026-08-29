require "test_helper"
require "hive/task_counter"

class TaskCounterTest < Minitest::Test
  include HiveTestHelper

  def setup
    @root = tracked_tmp_dir("hive-test-counter")
    @database = Hive::RuntimeControlPlane::Database.new(
      path: File.join(@root, "runtime.sqlite3")
    ).migrate!
    Hive::TaskCounter.database = @database
  end

  def teardown
    Hive::TaskCounter.database = nil
    @database&.disconnect
  end

  def test_sequential_allocation_and_floor_seed
    assert_equal [ 1, 2, 3 ], 3.times.map { Hive::TaskCounter.next! }
    assert_equal 4, Hive::TaskCounter.peek
    assert_equal 10, Hive::TaskCounter.seed_at_least!(10)
    assert_equal 10, Hive::TaskCounter.next!
    assert_equal 11, Hive::TaskCounter.seed_at_least!(3)
  end

  def test_multiprocess_allocations_are_unique
    readers = []
    children = 12.times.map do
      reader, writer = IO.pipe
      readers << reader
      Hive::RuntimeControlPlane::ProcessGuard.fork do
        reader.close
        writer.write("#{Hive::TaskCounter.next!}\n")
        writer.close
      end.tap { writer.close }
    end
    ids = readers.map { |reader| Integer(reader.read) }
    children.each { |pid| Process.wait(pid) }

    assert_equal (1..12).to_a, ids.sort
    assert_equal 13, Hive::TaskCounter.peek
  ensure
    readers.each { |reader| reader.close unless reader.closed? }
  end

  def test_allocation_uses_no_legacy_counter_files
    assert_equal 1, Hive::TaskCounter.next_or_nil
    refute File.exist?(File.join(Hive::Paths.state_home, "task-counter.yml"))
  end
end
