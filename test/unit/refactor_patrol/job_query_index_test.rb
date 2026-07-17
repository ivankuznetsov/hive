require "test_helper"
require "json"
require "hive/refactor_patrol/job_query_index"

class RefactorPatrolJobQueryIndexTest < Minitest::Test
  include HiveTestHelper

  class CorruptRecord < StandardError
    def initialize(message, path: nil)
      super(path ? "#{message}: #{path}" : message)
    end
  end

  class InconsistentRecord < CorruptRecord; end

  def test_reservation_crash_hides_later_membership_until_authoritative_rebuild
    with_index do |index, root|
      assert_raises(IOError) do
        index.with_registration("job-1", existing: false, migration_job_ids: -> { [] }) do
          raise IOError, "crash before job write"
        end
      end

      register(index, root, "job-2")
      page = index.page(limit: 10)
      assert_empty page.fetch("job_ids")
      assert_equal 0, page.fetch("total")

      index.rebuild! { [ "job-2" ] }
      assert_equal [ "job-2" ], index.page(limit: 10).fetch("job_ids")
    end
  end

  def test_job_write_crash_is_published_by_the_next_registration
    with_index do |index, root|
      assert_raises(IOError) do
        index.with_registration("job-1", existing: false, migration_job_ids: -> { [] }) do
          write_job(root, "job-1")
          raise IOError, "crash after job write"
        end
      end

      register(index, root, "job-2")
      page = index.page(limit: 10)
      assert_equal %w[job-1 job-2], page.fetch("job_ids")
      assert_equal 2, page.fetch("total")
    end
  end

  def test_exact_retry_adopts_membership_written_before_allocation_state
    with_index do |index, root|
      writes = 0
      original_write_state = index.method(:write_state)
      index.define_singleton_method(:write_state) do |state|
        writes += 1
        raise IOError, "crash before allocation state" if writes == 2

        original_write_state.call(state)
      end
      assert_raises(IOError) { register(index, root, "job-1") }
      index.singleton_class.send(:remove_method, :write_state)

      register(index, root, "job-1")

      page = index.page(limit: 10)
      assert_equal [ "job-1" ], page.fetch("job_ids")
      assert_equal 1, page.fetch("total")
    ensure
      index&.singleton_class&.send(:remove_method, :write_state) if index&.singleton_methods&.include?(:write_state)
    end
  end

  def test_failed_rebuild_keeps_the_live_generation_readable
    with_index do |index, root|
      register(index, root, "job-1")
      before = index.page(limit: 10)

      assert_raises(InconsistentRecord) { index.rebuild! { [ "missing" ] } }

      after = index.page(limit: 10)
      assert_equal before.fetch("generation"), after.fetch("generation")
      assert_equal [ "job-1" ], after.fetch("job_ids")
    end
  end

  def test_rebuild_preserves_caller_order_deduplicates_and_retains_old_generation
    with_index do |index, root|
      register(index, root, "job-a")
      old_generation = index.page(limit: 10).fetch("generation")
      write_job(root, "job-z")

      index.rebuild! { %w[job-z job-a job-z] }

      page = index.page(limit: 10)
      assert_equal %w[job-z job-a], page.fetch("job_ids")
      refute_equal old_generation, page.fetch("generation")
      assert Dir.exist?(File.join(index_root(root), "generations", old_generation))
    end
  end

  def test_registration_waiting_on_rebuild_is_appended_to_new_generation
    with_index do |index, root|
      register(index, root, "job-a")
      entered = Queue.new
      release = Queue.new
      writer_started = Queue.new
      writer_finished = Queue.new
      rebuild = Thread.new do
        index.rebuild! do
          entered << true
          release.pop
          [ "job-a" ]
        end
      end
      entered.pop
      writer = Thread.new do
        writer_started << true
        register(index, root, "job-b")
        writer_finished << true
      end
      writer_started.pop
      assert_raises(ThreadError) { writer_finished.pop(true) }

      release << true
      assert rebuild.join(2), "rebuild did not finish"
      assert writer.join(2), "writer did not finish"
      assert_equal %w[job-a job-b], index.page(limit: 10).fetch("job_ids")
    ensure
      release << true if release && rebuild&.alive?
      rebuild&.join(2)
      writer&.join(2)
    end
  end

  def test_fresh_generation_ancestors_are_fsynced_before_active_publication
    with_index do |index, root|
      fsynced = []
      original = Hive::AtomicFile.method(:fsync_directory)
      with_replaced_singleton_method(Hive::AtomicFile, :fsync_directory, lambda { |path|
        fsynced << path
        original.call(path)
      }) do
        register(index, root, "job-1")
      end

      generation = index.page(limit: 10).fetch("generation")
      query_root = index_root(root)
      generation_root = File.join(query_root, "generations", generation)
      assert_includes fsynced, query_root
      assert_includes fsynced, File.join(query_root, "generations")
      assert_includes fsynced, generation_root
      assert_includes fsynced, File.join(generation_root, "entries")
      assert_includes fsynced, File.join(generation_root, "by-job")
    end
  end

  def test_empty_index_read_is_non_mutating
    with_index do |index, root|
      assert_empty index.page(limit: 10).fetch("job_ids")
      refute Dir.exist?(index_root(root))
    end
  end

  def test_registration_requires_its_authoritative_job
    with_index do |index, _root|
      assert_raises(InconsistentRecord) do
        index.with_registration("job-1", existing: false, migration_job_ids: -> { [] }) do
          "job-1"
        end
      end
    end
  end

  def test_existing_job_must_appear_in_authoritative_migration
    with_index do |index, root|
      write_job(root, "job-1")
      write_job(root, "job-2")

      assert_raises(InconsistentRecord) do
        index.with_registration("job-1", existing: true, migration_job_ids: -> { [ "job-2" ] }) do
          "job-1"
        end
      end
    end
  end

  def test_page_rejects_missing_job_and_invalid_cursor_bounds
    with_index do |index, root|
      register(index, root, "job-1")
      cursor = {
        "generation" => index.page(limit: 10).fetch("generation"),
        "after_sequence" => 0,
        "through_sequence" => 2
      }
      assert_raises(Hive::RefactorPatrol::JobQueryIndex::CursorError) do
        index.page(limit: 10, cursor: cursor)
      end

      File.delete(File.join(root, "jobs", "job-1.json"))
      assert_raises(InconsistentRecord) { index.page(limit: 10) }
    end
  end

  def test_entry_only_crash_is_idempotent_and_conflicting_membership_fails_closed
    with_index do |index, root|
      writes = 0
      original = index.method(:write_immutable)
      index.define_singleton_method(:write_immutable) do |path, payload|
        writes += 1
        raise IOError, "crash before pointer" if writes == 2

        original.call(path, payload)
      end
      assert_raises(IOError) { register(index, root, "job-1") }
      index.singleton_class.send(:remove_method, :write_immutable)

      register(index, root, "job-1")
      assert_equal [ "job-1" ], index.page(limit: 10).fetch("job_ids")

      state = JSON.parse(File.read(File.join(index_root(root), "active.json")))
      entry = File.join(
        index_root(root), "generations", state.fetch("generation"),
        "entries", format("%020d.json", 2)
      )
      payload = index.send(:entry_payload, state, 2, "job-2")
      FileUtils.mkdir_p(File.dirname(entry))
      File.write(entry, JSON.generate(payload.merge("job_id" => "other")))
      assert_raises(InconsistentRecord) { register(index, root, "job-2") }
    ensure
      if index&.singleton_methods&.include?(:write_immutable)
        index.singleton_class.send(:remove_method, :write_immutable)
      end
    end
  end

  def test_noncontiguous_unpublished_pointer_and_corrupt_state_fail_closed
    with_index do |index, root|
      assert_raises(InconsistentRecord) do
        index.with_registration("job-1", existing: false, migration_job_ids: -> { [] }) { nil }
      end
      state_path = File.join(index_root(root), "active.json")
      state = JSON.parse(File.read(state_path))
      index.send(:write_membership!, state, 3, "job-3")
      assert_raises(InconsistentRecord) { register(index, root, "job-3") }

      File.write(state_path, "{")
      assert_raises(CorruptRecord) { index.page(limit: 10) }
    end
  end

  private

  def with_index
    with_tmp_dir do |dir|
      root = File.join(dir, "v2")
      index = Hive::RefactorPatrol::JobQueryIndex.new(
        root: root,
        id_pattern: /\A[a-z0-9-]+\z/,
        corrupt_record: CorruptRecord,
        inconsistent_record: InconsistentRecord
      )
      yield index, root
    end
  end

  def register(index, root, job_id)
    index.with_registration(job_id, existing: false, migration_job_ids: -> { [] }) do
      write_job(root, job_id)
      job_id
    end
  end

  def write_job(root, job_id)
    path = File.join(root, "jobs", "#{job_id}.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{}\n")
  end

  def index_root(root)
    File.join(root, "indexes", "job-query")
  end
end
