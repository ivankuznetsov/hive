require "test_helper"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/job_store_generation_cutover"

class RefactorPatrolJobStoreGenerationCutoverTest < Minitest::Test
  include HiveTestHelper

  NullWriterFence = Data.define do
    def assert_quiescent! = true
  end

  class MutatingManagedDirectory
    def initialize(delegate, mutation:)
      @delegate = delegate
      @mutation = mutation
      @source_reads = 0
    end

    def read_with_metadata(relative, **options)
      value = @delegate.read_with_metadata(relative, **options)
      if relative.include?(".job-schema-v3-source-")
        @source_reads += 1
        @mutation.call if @source_reads == 2
      end
      value
    end

    def method_missing(name, ...)
      @delegate.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @delegate.respond_to?(name, include_private) || super
    end
  end

  class ExplodingWriterFence
    def assert_quiescent!
      raise "writer fence reached"
    end
  end

  class InterruptingExchangeDirectory
    def initialize(delegate, timing:)
      @delegate = delegate
      @timing = timing
    end

    def exchange_directory_with_regular!(**attributes)
      raise Interrupt, "injected before source exchange" if
        @timing == :before

      @delegate.exchange_directory_with_regular!(**attributes)
      raise Interrupt, "injected after source exchange" if
        @timing == :after
    end

    def method_missing(name, ...)
      @delegate.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @delegate.respond_to?(name, include_private) || super
    end
  end

  class InterruptingPrepareDirectory
    def initialize(delegate)
      @delegate = delegate
    end

    def prepare!
      @delegate.prepare!
      raise Interrupt, "injected after target preparation"
    end

    def method_missing(name, ...)
      @delegate.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @delegate.respond_to?(name, include_private) || super
    end
  end

  class NoDeepReadDirectory
    def initialize(delegate)
      @delegate = delegate
    end

    def each_child(...)
      raise "deep inventory read reached"
    end

    def read_with_metadata(...)
      raise "deep record read reached"
    end

    def method_missing(name, ...)
      @delegate.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @delegate.respond_to?(name, include_private) || super
    end
  end

  def test_seals_released_jobs_before_conversion_and_admits_only_v3
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(
        state, "refactor_patrol", "v2"
      )
      target_root = File.join(
        state, "refactor_patrol", "v3"
      )
      source = install_released_job(legacy_root)
      manifest = File.join(legacy_root, "manifests", "job-released.json")
      FileUtils.mkdir_p(File.dirname(manifest))
      File.binwrite(manifest, "unrelated-v2-manifest")

      cutover = cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state
      )
      assert cutover.run!

      assert File.file?(File.join(legacy_root, "jobs"))
      assert_equal "unrelated-v2-manifest", File.binread(manifest)
      tombstone = JSON.parse(
        File.binread(File.join(legacy_root, "jobs"))
      )
      assert_equal "complete", tombstone.fetch("status")
      archive = File.join(
        legacy_root, tombstone.fetch("archive_name")
      )
      assert File.directory?(archive)
      assert_equal source, File.binread(
        File.join(archive, "job-released.json")
      )
      migrated = JSON.parse(File.binread(
        File.join(target_root, "jobs", "job-released.json")
      ))
      assert_equal 3, migrated.fetch("schema_version")
      assert_equal "current", cutover.status.fetch("status")
      assert_equal tombstone.fetch("snapshot_id"),
                   cutover.status.fetch("snapshot_id")
      refute cutover.run!

      assert_raises(SystemCallError) do
        FileUtils.mkdir_p(File.join(legacy_root, "jobs"))
      end
      assert_equal migrated, JSON.parse(File.binread(
        File.join(target_root, "jobs", "job-released.json")
      ))
    end
  end

  def test_resume_after_atomic_seal_uses_the_archived_source
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      target_root = File.join(state, "refactor_patrol", "v3")
      install_released_job(legacy_root)
      calls = 0
      failing_factory = lambda do |_root|
        calls += 1
        Object.new.tap do |migration|
          migration.define_singleton_method(:run!) do |transition_lock:|
            raise IOError, "injected after source seal"
          end
        end
      end
      interrupted = cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state,
        migration_factory: failing_factory
      )

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { interrupted.run! }
      assert_match(/injected after source seal/, error.message)
      assert_equal 1, calls
      assert File.file?(File.join(legacy_root, "jobs"))
      record = JSON.parse(File.binread(
        File.join(target_root, "job-schema-v3-cutover.json")
      ))
      assert_equal "sealed", record.fetch("status")
      assert File.directory?(
        File.join(legacy_root, record.fetch("archive_name"))
      )

      resumed = cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state
      )
      assert resumed.run!
      assert_equal "current", resumed.status.fetch("status")
    end
  end

  def test_native_v3_namespace_installs_a_permanent_legacy_write_barrier
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      target_root = File.join(state, "refactor_patrol", "v3")
      FileUtils.mkdir_p(File.join(legacy_root, "manifests"))
      File.binwrite(
        File.join(legacy_root, "manifests", "one.json"), "manifest"
      )
      cutover = cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state
      )

      refute cutover.run!
      assert cutover.ensure_native_namespace!

      tombstone = JSON.parse(
        File.binread(File.join(legacy_root, "jobs"))
      )
      assert_equal "native", tombstone.fetch("origin")
      assert_equal "complete", tombstone.fetch("status")
      assert_nil tombstone.fetch("snapshot_id")
      assert File.directory?(target_root)
      assert_equal "manifest", File.binread(
        File.join(legacy_root, "manifests", "one.json")
      )
      assert_equal "current", cutover.status.fetch("status")
    end
  end

  def test_refuses_when_an_already_open_released_writer_changes_the_sealed_source
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      target_root = File.join(state, "refactor_patrol", "v3")
      install_released_job(legacy_root)
      migration = cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state
      )
      archive_job = File.join(
        legacy_root,
        ".job-schema-v3-source-#{'a' * 32}",
        "job-released.json"
      )
      managed = Hive::ManagedDirectory.new(
        root: legacy_root,
        anchor: state,
        label: "mutating released JobStore"
      )
      migration.instance_variable_set(
        :@legacy_directory,
        MutatingManagedDirectory.new(
          managed,
          mutation: lambda do
            bytes = File.binread(archive_job)
            bytes.setbyte(0, bytes.getbyte(0) == "{".ord ? "[".ord : "{".ord)
            File.binwrite(archive_job, bytes)
          end
        )
      )

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { migration.run! }

      assert_match(/changed (?:before it was copied|while it was copied)/,
                   error.message)
      record = JSON.parse(File.binread(
        File.join(target_root, "job-schema-v3-cutover.json")
      ))
      assert_equal "sealed", record.fetch("status")
      assert_match(
        /\A[0-9a-f]{64}\z/,
        record.fetch("source_inventory_digest")
      )
      refute File.exist?(
        File.join(target_root, "job-schema-v3-complete.json")
      )
    end
  end

  def test_refuses_when_a_released_writer_changes_source_during_conversion
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      target_root = File.join(state, "refactor_patrol", "v3")
      install_released_job(legacy_root)
      archive_job = File.join(
        legacy_root,
        ".job-schema-v3-source-#{'a' * 32}",
        "job-released.json"
      )
      fake_factory = lambda do |_root|
        Object.new.tap do |migration|
          migration.define_singleton_method(:run!) do |transition_lock:|
            raise "transition lock must remain held" if transition_lock

            bytes = File.binread(archive_job)
            bytes.setbyte(
              0,
              bytes.getbyte(0) == "{".ord ? "[".ord : "{".ord
            )
            File.binwrite(archive_job, bytes)
            true
          end
          migration.define_singleton_method(:status) do
            {
              "status" => "current",
              "snapshot_id" => "snapshot-#{"b" * 64}"
            }
          end
        end
      end
      migration = cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state,
        migration_factory: fake_factory
      )

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { migration.run! }

      assert_match(/changed during schema conversion/, error.message)
      tombstone = JSON.parse(File.binread(
        File.join(legacy_root, "jobs")
      ))
      assert_equal "sealed", tombstone.fetch("status")
      record = JSON.parse(File.binread(
        File.join(target_root, "job-schema-v3-cutover.json")
      ))
      assert_equal "sealed", record.fetch("status")
    end
  end

  def test_completed_migration_skips_writer_fence_and_deep_inventory
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      target_root = File.join(state, "refactor_patrol", "v3")
      install_released_job(legacy_root)
      assert cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state
      ).run!

      completed = cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state,
        writer_fence: ExplodingWriterFence.new
      )
      completed.instance_variable_set(
        :@legacy_directory,
        NoDeepReadDirectory.new(
          Hive::ManagedDirectory.new(
            root: legacy_root,
            anchor: state,
            label: "completed released JobStore"
          )
        )
      )
      completed.instance_variable_set(
        :@target_directory,
        NoDeepReadDirectory.new(
          Hive::ManagedDirectory.new(
            root: target_root,
            anchor: state,
            label: "completed v3 JobStore"
          )
        )
      )

      assert_equal "current",
                   completed.admission_status.fetch("status")
      refute completed.run!
    end
  end

  def test_mismatched_completion_receipt_reaches_writer_fence
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      target_root = File.join(state, "refactor_patrol", "v3")
      install_released_job(legacy_root)
      assert cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state
      ).run!
      marker_path = File.join(
        target_root,
        Hive::RefactorPatrol::JobStoreSchemaMigration::MARKER_NAME
      )
      marker = JSON.parse(File.binread(marker_path))
      marker["snapshot_id"] = "snapshot-#{"f" * 64}"
      File.binwrite(
        marker_path,
        Hive::WorkflowPackage::CanonicalJSON.generate(marker)
      )

      repair = cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state,
        writer_fence: ExplodingWriterFence.new
      )
      assert_equal "migration_required",
                   repair.admission_status.fetch("status")
      error = assert_raises(RuntimeError) { repair.run! }
      assert_equal "writer fence reached", error.message
    end
  end

  def test_mismatched_completion_job_count_reaches_writer_fence
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      target_root = File.join(state, "refactor_patrol", "v3")
      install_released_job(legacy_root)
      assert cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state
      ).run!
      marker_path = File.join(
        target_root,
        Hive::RefactorPatrol::JobStoreSchemaMigration::MARKER_NAME
      )
      marker = JSON.parse(File.binread(marker_path))
      marker["migrated_jobs"] += 1
      File.binwrite(
        marker_path,
        Hive::WorkflowPackage::CanonicalJSON.generate(marker)
      )

      repair = cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state,
        writer_fence: ExplodingWriterFence.new
      )
      assert_equal "migration_required",
                   repair.admission_status.fetch("status")
      error = assert_raises(RuntimeError) { repair.run! }
      assert_equal "writer fence reached", error.message
    end
  end

  def test_atomic_write_residue_fails_before_source_seal_or_record
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      target_root = File.join(state, "refactor_patrol", "v3")
      install_released_job(legacy_root)
      File.binwrite(
        File.join(
          legacy_root,
          "jobs",
          ".job-released.json.tmp.123.abcdef12"
        ),
        "partial"
      )

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) do
        cutover(
          legacy_root: legacy_root,
          target_root: target_root,
          anchor: state
        ).run!
      end

      assert_match(/incomplete atomic write/, error.message)
      assert File.directory?(File.join(legacy_root, "jobs"))
      refute_path_exists File.join(
        target_root,
        Hive::RefactorPatrol::JobStoreGenerationCutover::RECORD_NAME
      )
      assert_empty Dir.glob(
        File.join(legacy_root, ".job-schema-v3-source-*")
      )
    end
  end

  def test_preflight_and_post_exchange_interruptions_resume_exactly
    %i[before after].each do |timing|
      with_tmp_dir do |project_root|
        state = File.join(project_root, ".hive-state")
        legacy_root = File.join(state, "refactor_patrol", "v2")
        target_root = File.join(state, "refactor_patrol", "v3")
        install_released_job(legacy_root)
        interrupted = cutover(
          legacy_root: legacy_root,
          target_root: target_root,
          anchor: state
        )
        interrupted.instance_variable_set(
          :@legacy_directory,
          InterruptingExchangeDirectory.new(
            Hive::ManagedDirectory.new(
              root: legacy_root,
              anchor: state,
              label: "interrupting released JobStore"
            ),
            timing: timing
          )
        )

        error = assert_raises(Interrupt) { interrupted.run! }
        assert_match(/source exchange/, error.message)
        record = JSON.parse(File.binread(File.join(
          target_root,
          Hive::RefactorPatrol::JobStoreGenerationCutover::RECORD_NAME
        )))
        assert_equal "preflighted", record.fetch("status")
        assert_match(
          /\A[0-9a-f]{64}\z/,
          record.fetch("source_inventory_digest")
        )
        expected_kind = timing == :before ? "directory" : "file"
        assert_equal expected_kind,
                     File.ftype(File.join(legacy_root, "jobs"))

        resumed = cutover(
          legacy_root: legacy_root,
          target_root: target_root,
          anchor: state
        )
        assert resumed.run!
        assert_equal "current",
                     resumed.admission_status.fetch("status")
      end
    end
  end

  def test_interrupted_native_preparation_is_repaired_but_nonempty_is_not
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      target_root = File.join(state, "refactor_patrol", "v3")
      interrupted = cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state
      )
      interrupted.instance_variable_set(
        :@target_directory,
        InterruptingPrepareDirectory.new(
          Hive::ManagedDirectory.new(
            root: target_root,
            anchor: state,
            label: "interrupting v3 JobStore"
          )
        )
      )

      error = assert_raises(Interrupt) do
        interrupted.ensure_native_namespace!
      end
      assert_match(/target preparation/, error.message)
      assert File.directory?(target_root)
      assert_empty Dir.children(target_root)

      repaired = cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state
      )
      assert_equal "migration_required",
                   repaired.admission_status.fetch("status")
      refute repaired.run!
      assert_equal "current",
                   repaired.admission_status.fetch("status")
    end

    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      legacy_root = File.join(state, "refactor_patrol", "v2")
      target_root = File.join(state, "refactor_patrol", "v3")
      FileUtils.mkdir_p(target_root)
      File.binwrite(File.join(target_root, "foreign"), "data")
      unsafe = cutover(
        legacy_root: legacy_root,
        target_root: target_root,
        anchor: state
      )

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { unsafe.run! }
      assert_match(/without a legacy jobs namespace/, error.message)
      refute_path_exists File.join(legacy_root, "jobs")
    end
  end

  private

  def install_released_job(legacy_root)
    source = File.binread(File.expand_path(
      "../../fixtures/refactor_patrol/released_v2_job.json", __dir__
    ))
    path = File.join(legacy_root, "jobs", "job-released.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, source)
    source
  end

  def cutover(legacy_root:, target_root:, anchor:, migration_factory: nil,
              writer_fence: NullWriterFence.new)
    Hive::RefactorPatrol::JobStoreGenerationCutover.new(
      legacy_root: legacy_root,
      target_root: target_root,
      target_version: Hive::RefactorPatrol::JobStore::SCHEMA_VERSION,
      validator: Hive::RefactorPatrol::JobRecordValidator.new(
        contract: Hive::RefactorPatrol::JobStore
      ),
      corrupt_record: Hive::RefactorPatrol::JobStore::CorruptRecord,
      inconsistent_record:
        Hive::RefactorPatrol::JobStore::InconsistentRecord,
      project: {
        "name" => "demo",
        "project_id" => "project-demo"
      },
      ownership: {
        "owner" => "legacy",
        "epoch" => 1
      },
      anchor: anchor,
      writer_fence: writer_fence,
      nonce: -> { "a" * 32 },
      migration_factory: migration_factory
    )
  end
end
