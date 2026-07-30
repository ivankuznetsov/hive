require "test_helper"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/job_store_fresh_start"

class RefactorPatrolJobStoreFreshStartTest < Minitest::Test
  include HiveTestHelper

  NullWriterFence = Data.define do
    def assert_quiescent! = true
  end

  class ExplodingWriterFence
    def assert_quiescent!
      raise Hive::ConcurrentRunError, "live daemon"
    end
  end

  class InterruptingTarget
    def initialize(delegate)
      @delegate = delegate
    end

    def prepare!
      @delegate.prepare!
      raise Interrupt, "injected after v3 preparation"
    end

    def method_missing(name, ...)
      @delegate.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @delegate.respond_to?(name, include_private) || super
    end
  end

  class InterruptingExchange
    def initialize(delegate)
      @delegate = delegate
    end

    def exchange_directory_with_regular!(...)
      raise Interrupt, "injected before source exchange"
    end

    def method_missing(name, ...)
      @delegate.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @delegate.respond_to?(name, include_private) || super
    end
  end

  def test_archives_opaque_v2_jobs_and_activates_an_empty_v3_store
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      legacy_jobs = File.join(legacy_root, "jobs")
      FileUtils.mkdir_p(File.join(legacy_jobs, "nested"))
      File.binwrite(File.join(legacy_jobs, "opaque.bin"), "\x00v2\xff".b)
      File.binwrite(File.join(legacy_jobs, "nested", "state"), "untouched")
      FileUtils.mkdir_p(File.join(legacy_root, "manifests"))
      File.binwrite(
        File.join(legacy_root, "manifests", "merge.json"),
        "still-current"
      )
      reset = fresh_start(project_root, state: state)

      assert_equal "reset_required", reset.status.fetch("status")
      refute File.exist?(
        File.join(
          state, "refactor_patrol", ".jobstore-generation.lock"
        )
      ), "read-only status must not create the generation lock"
      result = reset.reset!

      assert_equal true, result.fetch("changed")
      assert_equal "current", result.fetch("status")
      assert File.file?(legacy_jobs)
      archive = result.fetch("archive_path")
      assert File.directory?(archive)
      assert_equal "\x00v2\xff".b,
                   File.binread(File.join(archive, "opaque.bin"))
      assert_equal "untouched",
                   File.binread(File.join(archive, "nested", "state"))
      assert_equal "still-current", File.binread(
        File.join(legacy_root, "manifests", "merge.json")
      )
      assert_empty Dir.children(
        File.join(state, "refactor_patrol", "v3")
      )
      assert File.file?(
        File.join(
          state,
          "refactor_patrol",
          Hive::RefactorPatrol::JobStoreFreshStart::RECEIPT_NAME
        )
      )
      assert_equal "current", reset.status.fetch("status")
      assert_equal false, reset.reset!.fetch("changed")
    end
  end

  def test_resume_after_source_exchange_reuses_the_same_archive
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      FileUtils.mkdir_p(File.join(legacy_root, "jobs"))
      File.binwrite(File.join(legacy_root, "jobs", "one"), "one")
      interrupted = fresh_start(project_root, state: state)
      target = Hive::ManagedDirectory.new(
        root: File.join(state, "refactor_patrol", "v3"),
        anchor: state,
        label: "interrupted v3 JobStore"
      )
      interrupted.instance_variable_set(
        :@target_directory, InterruptingTarget.new(target)
      )

      assert_raises(Interrupt) { interrupted.reset! }
      pending = interrupted.status
      assert_equal "reset_incomplete", pending.fetch("status")
      archive = pending.fetch("archive_path")
      assert File.directory?(archive)
      assert_equal "one", File.binread(File.join(archive, "one"))

      resumed = fresh_start(project_root, state: state)
      completed = resumed.reset!
      assert_equal "current", completed.fetch("status")
      assert_equal archive, completed.fetch("archive_path")
      assert_equal "one", File.binread(File.join(archive, "one"))
    end
  end

  def test_resume_before_source_exchange_reuses_the_persisted_marker
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      jobs = File.join(legacy_root, "jobs")
      FileUtils.mkdir_p(jobs)
      File.binwrite(File.join(jobs, "one"), "one")
      interrupted = fresh_start(project_root, state: state)
      directory = Hive::ManagedDirectory.new(
        root: legacy_root,
        anchor: state,
        label: "interrupted released JobStore"
      )
      interrupted.instance_variable_set(
        :@legacy_directory, InterruptingExchange.new(directory)
      )

      assert_raises(Interrupt) { interrupted.reset! }
      assert_equal "reset_required", interrupted.status.fetch("status")
      expected_suffix = "a" * 32
      pending = File.join(
        legacy_root, ".jobs-v2-archive-#{expected_suffix}"
      )
      assert File.file?(pending)
      marker_bytes = File.binread(pending)

      completed = fresh_start(project_root, state: state).reset!

      assert_equal pending, completed.fetch("archive_path")
      assert File.directory?(pending)
      assert_equal "one", File.binread(File.join(pending, "one"))
      assert_equal(
        Digest::SHA256.hexdigest(marker_bytes),
        JSON.parse(File.binread(
          completed.fetch("receipt_path")
        )).fetch("marker_digest")
      )
    end
  end

  def test_refuses_a_foreign_pending_marker_before_source_exchange
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      jobs = File.join(legacy_root, "jobs")
      FileUtils.mkdir_p(jobs)
      File.binwrite(File.join(jobs, "one"), "one")
      expected_suffix = "a" * 32
      expected_archive = File.join(
        legacy_root, ".jobs-v2-archive-#{expected_suffix}"
      )
      foreign_suffix = "b" * 32
      File.binwrite(
        expected_archive,
        Hive::WorkflowPackage::CanonicalJSON.generate(
          reset_marker(foreign_suffix)
        )
      )

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        fresh_start(project_root, state: state).reset!
      end

      assert_match(/archive marker identity conflicts/, error.message)
      assert File.directory?(jobs)
      assert_equal "one", File.binread(File.join(jobs, "one"))
    end
  end

  def test_fresh_v3_initialization_does_not_manufacture_a_v2_namespace
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      reset = fresh_start(project_root, state: state)

      assert_equal "fresh", reset.status.fetch("status")
      refute File.exist?(File.join(state, "refactor_patrol"))
      assert reset.ensure_current!
      assert_equal "current", reset.status.fetch("status")
      assert File.directory?(File.join(state, "refactor_patrol", "v3"))
      refute File.exist?(File.join(state, "refactor_patrol", "v2"))
    end
  end

  def test_writer_fence_blocks_before_v2_is_archived
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      jobs = File.join(state, "refactor_patrol", "v2", "jobs")
      FileUtils.mkdir_p(jobs)
      File.binwrite(File.join(jobs, "one"), "one")
      reset = fresh_start(
        project_root,
        state: state,
        writer_fence: ExplodingWriterFence.new
      )

      assert_raises(Hive::ConcurrentRunError) { reset.reset! }
      assert File.directory?(jobs)
      assert_equal [ "one" ], Dir.children(jobs)
    end
  end

  def test_runtime_admission_requires_explicit_reset
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(File.join(state, "refactor_patrol", "v2", "jobs"))

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        Hive::RefactorPatrol::JobStore.new(
          project_root,
          hive_state_path: state,
          project: project_identity(project_root, state)
        )
      end

      assert_match(/explicit fresh-start reset is required/, error.message)
      refute File.exist?(File.join(state, "refactor_patrol", "v3"))
    end
  end

  def test_refuses_foreign_regular_file_at_the_v2_jobs_name
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      path = File.join(state, "refactor_patrol", "v2", "jobs")
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, "not-a-reset-marker")

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { fresh_start(project_root, state: state).status }

      assert_match(/reset marker is malformed/, error.message)
    end
  end

  def test_refuses_to_reset_over_an_existing_nonempty_v3_store
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(File.join(state, "refactor_patrol", "v2", "jobs"))
      current = File.join(state, "refactor_patrol", "v3")
      FileUtils.mkdir_p(File.join(current, "jobs"))
      File.binwrite(File.join(current, "jobs", "new.json"), "{}")

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { fresh_start(project_root, state: state).reset! }

      assert_match(/v3 JobStore is not empty/, error.message)
      assert File.directory?(
        File.join(state, "refactor_patrol", "v2", "jobs")
      )
    end
  end

  private

  def fresh_start(project_root, state:, writer_fence: NullWriterFence.new)
    Hive::RefactorPatrol::JobStoreFreshStart.new(
      state_root: state,
      project: project_identity(project_root, state),
      target_version: Hive::RefactorPatrol::JobStore::SCHEMA_VERSION,
      corrupt_record: Hive::RefactorPatrol::JobStore::CorruptRecord,
      inconsistent_record:
        Hive::RefactorPatrol::JobStore::InconsistentRecord,
      writer_fence: writer_fence,
      nonce: -> { "a" * 32 },
      clock: -> { Time.utc(2026, 7, 30, 9, 0, 0) }
    )
  end

  def project_identity(project_root, state)
    {
      "name" => "demo",
      "project_id" => "project-demo",
      "path" => project_root,
      "real_path" => File.realpath(project_root),
      "hive_state_path" => state
    }
  end

  def reset_marker(suffix)
    {
      "schema" =>
        Hive::RefactorPatrol::JobStoreFreshStart::SCHEMA,
      "schema_version" =>
        Hive::RefactorPatrol::JobStoreFreshStart::SCHEMA_VERSION,
      "project_id" => "project-demo",
      "source_generation" => "v2",
      "target_generation" => "v3",
      "target_schema_version" =>
        Hive::RefactorPatrol::JobStore::SCHEMA_VERSION,
      "transaction_id" => "reset-#{suffix}",
      "archive_name" => ".jobs-v2-archive-#{suffix}",
      "archived_at" => "2026-07-30T09:00:00Z"
    }
  end
end
