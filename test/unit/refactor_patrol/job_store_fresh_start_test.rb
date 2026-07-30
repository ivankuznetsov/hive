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

  class MutatingExchange
    def initialize(delegate, marker_path)
      @delegate = delegate
      @marker_path = marker_path
    end

    def exchange_directory_with_regular!(...)
      @delegate.exchange_directory_with_regular!(...)
      marker = JSON.parse(File.binread(@marker_path))
      marker["archived_at"] = "2026-07-30T09:00:01Z"
      File.binwrite(
        @marker_path,
        Hive::WorkflowPackage::CanonicalJSON.generate(marker)
      )
    end

    def method_missing(name, ...)
      @delegate.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @delegate.respond_to?(name, include_private) || super
    end
  end

  class SubstitutingReceiptDirectory
    def initialize(delegate)
      @delegate = delegate
    end

    def atomic_write(relative, bytes, **options)
      if relative ==
         Hive::RefactorPatrol::JobStoreFreshStart::RECEIPT_NAME
        receipt = JSON.parse(bytes)
        receipt["completed_at"] = "2026-07-30T09:00:01Z"
        bytes = Hive::WorkflowPackage::CanonicalJSON.generate(receipt)
      end
      @delegate.atomic_write(relative, bytes, **options)
    end

    def method_missing(name, ...)
      @delegate.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @delegate.respond_to?(name, include_private) || super
    end
  end

  ErrorWriterFence = Data.define(:error) do
    def assert_quiescent! = raise(error)
  end

  FillingWriterFence = Data.define(:target_root) do
    def assert_quiescent!
      FileUtils.mkdir_p(target_root)
      File.binwrite(File.join(target_root, "late-job"), "occupied")
      true
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
      assert reset.ensure_current!,
             "current v3 admission must remain idempotent"
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

  def test_archive_without_its_public_marker_blocks_status_and_runtime
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      identity = project_identity(project_root, state)
      archive_name =
        Hive::RefactorPatrol::JobStoreFreshStart.archive_name_for(
          identity.fetch("project_id")
        )
      archive = File.join(
        state, "refactor_patrol", "v2", archive_name
      )
      FileUtils.mkdir_p(archive)
      File.binwrite(File.join(archive, "opaque"), "preserved")
      reset = Hive::RefactorPatrol::JobStoreFreshStart.new(
        state_root: state,
        project: identity,
        target_version: Hive::RefactorPatrol::JobStore::SCHEMA_VERSION,
        corrupt_record: Hive::RefactorPatrol::JobStore::CorruptRecord,
        inconsistent_record:
          Hive::RefactorPatrol::JobStore::InconsistentRecord,
        writer_fence: NullWriterFence.new
      )

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { reset.status }
      assert_match(/archive.*without its reset marker/, error.message)

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) do
        Hive::RefactorPatrol::JobStore.new(
          project_root,
          hive_state_path: state,
          project: identity
        )
      end
      assert_match(/archive.*without its reset marker/, error.message)
      assert_equal "preserved",
                   File.binread(File.join(archive, "opaque"))
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

  def test_rejects_invalid_constructor_identity
    error = assert_raises(ArgumentError) do
      Hive::RefactorPatrol::JobStoreFreshStart.new(
        state_root: "/tmp/fresh-start-invalid",
        project: {},
        target_version: "invalid",
        corrupt_record: Hive::RefactorPatrol::JobStore::CorruptRecord,
        inconsistent_record:
          Hive::RefactorPatrol::JobStore::InconsistentRecord
      )
    end

    assert_match(/invalid JobStore fresh-start identity/, error.message)
  end

  def test_status_and_runtime_admission_wrap_storage_failures
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(File.join(state, "refactor_patrol"))
      reset = fresh_start(project_root, state: state)
      reset.define_singleton_method(:inspect_status) do
        raise Hive::ConfigError, "synthetic unsafe storage"
      end

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { reset.status }
      assert_match(/cannot inspect/, error.message)

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { reset.ensure_current! }
      assert_match(/cannot establish/, error.message)
    end
  end

  def test_runtime_admission_rejects_required_reset_and_generation_conflict
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(
        File.join(state, "refactor_patrol", "v2", "jobs")
      )
      reset = fresh_start(project_root, state: state)

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { reset.ensure_current! }
      assert_match(/explicit fresh-start reset is required/, error.message)

      target = File.join(state, "refactor_patrol", "v3")
      FileUtils.mkdir_p(target)
      File.binwrite(File.join(target, "job"), "occupied")
      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { reset.ensure_current! }
      assert_match(/generation conflict/, error.message)
    end
  end

  def test_reset_of_a_genuinely_fresh_project_is_a_no_op
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")

      result = fresh_start(project_root, state: state).reset!

      assert_equal "fresh", result.fetch("status")
      assert_equal false, result.fetch("changed")
      refute File.exist?(File.join(state, "refactor_patrol", "v3"))
    end
  end

  def test_reset_wraps_unexpected_writer_and_timestamp_failures
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(
        File.join(state, "refactor_patrol", "v2", "jobs")
      )
      reset = fresh_start(
        project_root,
        state: state,
        writer_fence: ErrorWriterFence.new(IOError.new("writer probe"))
      )

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { reset.reset! }
      assert_match(/fresh-start reset is unsafe.*writer probe/, error.message)

      reset = fresh_start(
        project_root,
        state: state,
        clock: -> { "2026-07-30T09:00:00+00:00" }
      )
      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { reset.reset! }
      assert_match(/timestamp is not canonical UTC/, error.message)
    end
  end

  def test_default_clock_nonce_and_malformed_nonce_paths
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(
        File.join(state, "refactor_patrol", "v2", "jobs")
      )
      reset = Hive::RefactorPatrol::JobStoreFreshStart.new(
        state_root: state,
        project: project_identity(project_root, state),
        target_version: Hive::RefactorPatrol::JobStore::SCHEMA_VERSION,
        corrupt_record: Hive::RefactorPatrol::JobStore::CorruptRecord,
        inconsistent_record:
          Hive::RefactorPatrol::JobStore::InconsistentRecord,
        writer_fence: NullWriterFence.new
      )

      assert_equal "current", reset.reset!.fetch("status")
    end

    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(
        File.join(state, "refactor_patrol", "v2", "jobs")
      )
      reset = fresh_start(
        project_root, state: state, nonce: -> { "malformed" }
      )

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { reset.reset! }
      assert_match(/fresh-start nonce is malformed/, error.message)
    end
  end

  def test_status_rejects_a_non_directory_v3_namespace
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      generation = File.join(state, "refactor_patrol")
      FileUtils.mkdir_p(generation)
      File.binwrite(File.join(generation, "v3"), "not-a-directory")
      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { fresh_start(project_root, state: state).status }
      assert_match(/v3 JobStore root is not a directory/, error.message)
    end
  end

  def test_status_rejects_receipt_without_v3_or_marker
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      jobs = File.join(state, "refactor_patrol", "v2", "jobs")
      FileUtils.mkdir_p(jobs)
      reset = fresh_start(project_root, state: state)
      reset.reset!

      FileUtils.remove_entry(
        File.join(state, "refactor_patrol", "v3")
      )
      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { reset.status }
      assert_match(/receipt exists without the v3 namespace/, error.message)

      FileUtils.mkdir_p(File.join(state, "refactor_patrol", "v3"))
      FileUtils.rm_f(jobs)
      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { reset.status }
      assert_match(/receipt exists without its v2 marker/, error.message)
    end
  end

  def test_status_reports_conflict_when_v3_changes_after_source_exchange
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      FileUtils.mkdir_p(File.join(legacy_root, "jobs"))
      reset = fresh_start(project_root, state: state)
      target = Hive::ManagedDirectory.new(
        root: File.join(state, "refactor_patrol", "v3"),
        anchor: state,
        label: "interrupted v3 JobStore"
      )
      reset.instance_variable_set(
        :@target_directory, InterruptingTarget.new(target)
      )
      assert_raises(Interrupt) { reset.reset! }
      File.binwrite(
        File.join(state, "refactor_patrol", "v3", "late-job"),
        "occupied"
      )

      assert_equal "conflict", reset.status.fetch("status")
    end
  end

  def test_reset_rejects_late_v3_population_after_initial_inspection
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      target = File.join(state, "refactor_patrol", "v3")
      FileUtils.mkdir_p(
        File.join(state, "refactor_patrol", "v2", "jobs")
      )
      reset = fresh_start(
        project_root,
        state: state,
        writer_fence: FillingWriterFence.new(target)
      )

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { reset.reset! }

      assert_match(/refusing to overwrite current state/, error.message)
      assert File.directory?(
        File.join(state, "refactor_patrol", "v2", "jobs")
      )
    end
  end

  def test_reset_rejects_occupied_archive_name_and_changed_sealed_marker
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy = File.join(state, "refactor_patrol", "v2")
      FileUtils.mkdir_p([
        File.join(legacy, "jobs"),
        File.join(legacy, ".jobs-v2-archive-#{"a" * 32}")
      ])
      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { fresh_start(project_root, state: state).reset! }
      assert_match(/archive name is already occupied/, error.message)
    end

    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy = File.join(state, "refactor_patrol", "v2")
      marker_path = File.join(legacy, "jobs")
      FileUtils.mkdir_p(marker_path)
      reset = fresh_start(project_root, state: state)
      delegate = Hive::ManagedDirectory.new(
        root: legacy,
        anchor: state,
        label: "mutating released JobStore"
      )
      reset.instance_variable_set(
        :@legacy_directory,
        MutatingExchange.new(delegate, marker_path)
      )

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { reset.reset! }
      assert_match(/marker changed during source sealing/, error.message)
    end
  end

  def test_reset_rejects_invalid_marker_receipt_and_archive_bindings
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy = File.join(state, "refactor_patrol", "v2")
      FileUtils.mkdir_p(legacy)
      marker = reset_marker("a" * 32)
      marker["archive_name"] = ".jobs-v2-archive-#{"b" * 32}"
      File.binwrite(
        File.join(legacy, "jobs"),
        Hive::WorkflowPackage::CanonicalJSON.generate(marker)
      )
      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { fresh_start(project_root, state: state).status }
      assert_match(/marker archive identity conflicts/, error.message)
    end

    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      jobs = File.join(state, "refactor_patrol", "v2", "jobs")
      FileUtils.mkdir_p(jobs)
      reset = fresh_start(project_root, state: state)
      result = reset.reset!
      receipt = JSON.parse(File.binread(result.fetch("receipt_path")))
      receipt["marker_digest"] = "b" * 64
      File.binwrite(
        result.fetch("receipt_path"),
        Hive::WorkflowPackage::CanonicalJSON.generate(receipt)
      )
      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { reset.status }
      assert_match(/receipt conflicts with marker/, error.message)
    end

    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy = File.join(state, "refactor_patrol", "v2")
      FileUtils.mkdir_p(legacy)
      File.binwrite(
        File.join(legacy, "jobs"),
        Hive::WorkflowPackage::CanonicalJSON.generate(
          reset_marker("a" * 32)
        )
      )
      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { fresh_start(project_root, state: state).status }
      assert_match(/archived v2 JobStore directory is unavailable/,
                   error.message)
    end
  end

  def test_receipt_write_is_idempotent_and_rejects_substitution
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(
        File.join(state, "refactor_patrol", "v2", "jobs")
      )
      reset = fresh_start(project_root, state: state)
      reset.reset!
      marker = reset.send(:marker_record)

      existing = reset.send(:write_completion_receipt!, marker)

      assert_equal marker.fetch("transaction_id"),
                   existing.fetch("transaction_id")
    end

    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(
        File.join(state, "refactor_patrol", "v2", "jobs")
      )
      reset = fresh_start(project_root, state: state)
      delegate = reset.instance_variable_get(:@generation_directory)
      reset.instance_variable_set(
        :@generation_directory,
        SubstitutingReceiptDirectory.new(delegate)
      )

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { reset.reset! }
      assert_match(/receipt changed after write/, error.message)
    end
  end

  def test_reset_requires_a_completed_current_status
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(
        File.join(state, "refactor_patrol", "v2", "jobs")
      )
      reset = fresh_start(project_root, state: state)
      original = reset.method(:inspect_status)
      calls = 0
      reset.define_singleton_method(:inspect_status) do
        calls += 1
        calls == 1 ? original.call :
          send(:status_payload, "reset_incomplete")
      end

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { reset.reset! }
      assert_match(/receipt did not admit v3/, error.message)
    end
  end

  private

  def fresh_start(
    project_root, state:, writer_fence: NullWriterFence.new,
    nonce: -> { "a" * 32 },
    clock: -> { Time.utc(2026, 7, 30, 9, 0, 0) }
  )
    Hive::RefactorPatrol::JobStoreFreshStart.new(
      state_root: state,
      project: project_identity(project_root, state),
      target_version: Hive::RefactorPatrol::JobStore::SCHEMA_VERSION,
      corrupt_record: Hive::RefactorPatrol::JobStore::CorruptRecord,
      inconsistent_record:
        Hive::RefactorPatrol::JobStore::InconsistentRecord,
      writer_fence: writer_fence,
      nonce: nonce,
      clock: clock
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
