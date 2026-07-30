require "test_helper"
require "json"
require "hive/refactor_patrol/job_store_files"

class RefactorPatrolJobStoreFilesTest < Minitest::Test
  include HiveTestHelper

  class CorruptRecord < StandardError
    def initialize(message, path: nil)
      super(path ? "#{message}: #{path}" : message)
    end
  end

  class InconsistentRecord < CorruptRecord; end

  def test_job_namespace_swap_cannot_redirect_reads_or_writes
    with_files do |files, root, outside|
      files.write_json("jobs/job-1.json", { "owned" => true })
      swap_directory(root, outside, "jobs")
      external = File.join(outside, "jobs", "job-1.json")
      File.write(external, JSON.generate("owned" => false))
      before = File.binread(external)

      assert_raises(Hive::ConfigError) do
        files.read_json("jobs/job-1.json")
      end
      assert_raises(Hive::ConfigError) do
        files.write_json("jobs/job-2.json", { "redirected" => true })
      end
      assert_equal before, File.binread(external)
      refute_path_exists File.join(outside, "jobs", "job-2.json")
    end
  end

  def test_query_index_namespace_swap_cannot_redirect_publication
    with_files do |files, root, outside|
      files.write_json(
        "indexes/job-query/active.json",
        { "generation" => "owned" }
      )
      swap_directory(root, outside, "indexes")
      external = File.join(
        outside, "indexes", "job-query", "active.json"
      )
      FileUtils.mkdir_p(File.dirname(external))
      File.write(external, JSON.generate("generation" => "external"))
      before = File.binread(external)

      assert_raises(Hive::ConfigError) do
        files.write_json(
          "indexes/job-query/active.json",
          { "generation" => "redirected" }
        )
      end
      assert_equal before, File.binread(external)
    end
  end

  def test_quarantine_namespace_swap_cannot_redirect_evidence
    with_files do |files, root, outside|
      files.write_json(
        "quarantine/jobs/owned.json",
        { "reason" => "owned" }
      )
      swap_directory(root, outside, "quarantine")

      assert_raises(Hive::ConfigError) do
        files.write_json(
          "quarantine/jobs/redirected.json",
          { "reason" => "redirected" }
        )
      end
      refute_path_exists File.join(
        outside, "quarantine", "jobs", "redirected.json"
      )
    end
  end

  def test_action_lock_symlink_cannot_redirect_flock
    with_files do |files, root, outside|
      external = File.join(outside, "actions.lock")
      File.write(external, "external")
      File.symlink(external, File.join(root, "actions.lock"))
      before = File.binread(external)
      entered = false

      assert_raises(Hive::ConfigError) do
        files.with_action_catalog_lock { entered = true }
      end
      refute entered
      assert_equal before, File.binread(external)
    end
  end

  def test_capacity_rejection_happens_before_per_job_lock_creation
    with_files do |files, root, _outside|
      files.write_json("jobs/job-1.json", {})

      with_constant(
        Hive::RefactorPatrol::JobStoreFiles,
        :MAX_JOB_ENTRIES,
        1
      ) do
        assert_raises(InconsistentRecord) do
          files.with_job_admission("job-2") { flunk }
        end
      end

      refute_path_exists File.join(root, "jobs", "job-2.json.lock")
      assert_equal [ "job-1" ], files.each_job_id.to_a
    end
  end

  def test_job_read_write_helpers_round_trip_exact_bytes
    with_files do |files, _root, _outside|
      bytes = "{\"job_id\":\"job-1\"}\n"

      files.write_job("job-1", bytes)

      assert_equal bytes, files.read_job("job-1")
      assert files.job_exists?("job-1")
      assert_equal [ "job-1" ], files.each_job_id.to_a
    end
  end

  def test_inventory_rejects_unknown_and_nonregular_entries
    with_files do |files, root, _outside|
      FileUtils.mkdir_p(File.join(root, "jobs"))
      File.binwrite(File.join(root, "jobs", "unknown.txt"), "x")

      error = assert_raises(CorruptRecord) { files.each_job_id.to_a }
      assert_match(/unknown entry/, error.message)

      FileUtils.rm_f(File.join(root, "jobs", "unknown.txt"))
      FileUtils.mkdir_p(File.join(root, "jobs", "job-dir.json"))
      error = assert_raises(CorruptRecord) { files.each_job_id.to_a }
      assert_match(/not a regular file/, error.message)
      error = assert_raises(CorruptRecord) do
        files.regular?("jobs/job-dir.json")
      end
      assert_match(/not a regular file/, error.message)
    end
  end

  def test_inventory_translates_a_job_that_disappears_after_enumeration
    with_files do |files, _root, _outside|
      files.write_job("job-1", "{}\n")
      original = files.method(:regular?)

      with_replaced_singleton_method(
        files,
        :regular?,
        lambda do |relative|
          relative == "jobs/job-1.json" ? false : original.call(relative)
        end
      ) do
        error = assert_raises(CorruptRecord) do
          files.each_job_id.to_a
        end
        assert_match(/job is not a regular file/, error.message)
      end
    end
  end

  private

  def with_constant(owner, name, replacement)
    original = owner.const_get(name, false)
    owner.send(:remove_const, name)
    owner.const_set(name, replacement)
    yield
  ensure
    owner.send(:remove_const, name) if owner.const_defined?(name, false)
    owner.const_set(name, original)
  end

  def with_files
    with_tmp_dir do |dir|
      root = File.join(dir, "state", "refactor_patrol", "v3")
      outside = File.join(dir, "outside")
      FileUtils.mkdir_p([ File.dirname(root), outside ])
      files = Hive::RefactorPatrol::JobStoreFiles.new(
        root: root,
        anchor: File.join(dir, "state"),
        corrupt_record: CorruptRecord,
        inconsistent_record: InconsistentRecord
      )
      files.prepare!
      yield files, root, outside
    end
  end

  def swap_directory(root, outside, name)
    owned = File.join(root, name)
    external = File.join(outside, name)
    FileUtils.mkdir_p(external)
    File.rename(owned, "#{owned}.parked")
    File.symlink(external, owned)
  end
end
