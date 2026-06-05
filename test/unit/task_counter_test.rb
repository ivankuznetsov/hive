require "test_helper"
require "hive/task_counter"

class TaskCounterTest < Minitest::Test
  include HiveTestHelper

  def test_first_call_returns_one_and_writes_next_id
    with_tmp_global_config do
      assert_equal 1, Hive::TaskCounter.next!
      assert_equal 2, YAML.safe_load(File.read(Hive::Paths.task_counter_path))["next_id"]
    end
  end

  def test_sequential_calls_are_increasing
    with_tmp_global_config do
      assert_equal [ 1, 2, 3 ], 3.times.map { Hive::TaskCounter.next! }
      assert_equal 4, Hive::TaskCounter.peek
    end
  end

  def test_corrupt_counter_defaults_to_one
    with_tmp_global_config do
      File.write(Hive::Paths.task_counter_path, ":\n:not yaml")
      assert_equal 1, Hive::TaskCounter.next!
      assert_equal 2, Hive::TaskCounter.peek
    end
  end

  def test_seed_at_least_does_not_move_counter_backwards
    with_tmp_global_config do
      assert_equal 10, Hive::TaskCounter.seed_at_least!(10)
      assert_equal 10, Hive::TaskCounter.next!
      assert_equal 11, Hive::TaskCounter.peek

      assert_equal 11, Hive::TaskCounter.seed_at_least!(3)
      assert_equal 11, Hive::TaskCounter.next!
    end
  end

  def test_concurrent_forks_allocate_distinct_ids
    with_tmp_global_config do
      readers = []
      children = 8.times.map do
        reader, writer = IO.pipe
        readers << reader
        fork do
          reader.close
          writer.write("#{Hive::TaskCounter.next!}\n")
          writer.close
        end.tap { writer.close }
      end

      ids = readers.map { |reader| reader.read.to_i }
      children.each { |pid| Process.wait(pid) }

      assert_equal (1..8).to_a, ids.sort
      assert_equal 9, Hive::TaskCounter.peek
    end
  end

  def test_lock_timeout_raises_typed_error
    with_tmp_global_config do
      FileUtils.mkdir_p(Hive::Paths.state_home)
      reader, writer = IO.pipe
      child = fork do
        reader.close
        File.open(Hive::Paths.task_counter_lock_path, File::RDWR | File::CREAT, 0o644) do |file|
          file.flock(File::LOCK_EX)
          writer.write("locked\n")
          writer.close
          sleep 5
        end
      end
      writer.close
      assert_equal "locked\n", reader.gets

      error = assert_raises(Hive::ConcurrentRunError) { Hive::TaskCounter.next!(timeout_sec: 0.01) }
      assert_match(/task counter lock/, error.message)
      assert_equal Hive::Paths.task_counter_lock_path, error.lock_path
    ensure
      Process.kill("KILL", child) if child
      Process.wait(child) if child
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end
  end
end
