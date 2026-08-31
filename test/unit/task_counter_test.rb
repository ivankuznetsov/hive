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

  def test_peek_infers_the_floor_from_numeric_task_subject_ids
    now = Time.now.utc.iso8601(6)
    @database.transaction do |db|
      installation_id = db[:installations].get(:installation_id)
      db[:projects].insert(
        project_id: "counter-project", installation_id: installation_id,
        registration_id: "counter", name: "counter", observed_path: "/tmp/counter",
        state_root_path: "/tmp/counter/.hive-state", active: 1,
        registered_at: now, last_observed_at: now
      )
      %w[41 not-numeric].each_with_index do |task_id, index|
        db[:task_subjects].insert(
          task_id: task_id, project_id: "counter-project", workflow_id: "coding",
          task_slug: "task-#{index}", observed_path: "/tmp/counter/task-#{index}",
          source_fingerprint: "f" * 64, generation: 1,
          created_at: now, last_observed_at: now
        )
      end
    end

    assert_equal 42, Hive::TaskCounter.peek
  end
end
