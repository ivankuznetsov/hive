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

  def test_cutover_rejects_incomplete_migration_status_and_receipt
    with_tmp_dir do |root|
      state = File.join(root, "state")
      FileUtils.mkdir_p(state)
      target = File.join(state, "v3")
      legacy = File.join(state, "v2")
      record = {
        "archive_name" => ".job-schema-v3-source-#{"a" * 32}",
        "status" => "sealed"
      }

      build = lambda do |migration|
        value = cutover(
          legacy_root: legacy,
          target_root: target,
          anchor: state,
          migration_factory: ->(_root) { migration }
        )
        value.define_singleton_method(:legacy_jobs_type) { :directory }
        value.define_singleton_method(:native_tombstone?) { |_kind| false }
        value.define_singleton_method(:completed_migrated_receipt) { |_kind| nil }
        value.define_singleton_method(:prepare_record) { record }
        value.define_singleton_method(:seal_source!) do |candidate, kind:|
          raise "unexpected source kind" unless kind == :directory

          candidate
        end
        value.define_singleton_method(:copy_sealed_source!) { |_candidate| true }
        value.define_singleton_method(:assert_source_inventory!) { |*, **| true }
        value.define_singleton_method(:sealed_source_inventory) { |_archive| [] }
        value
      end

      bad_status = Object.new
      bad_status.define_singleton_method(:run!) { |**| true }
      bad_status.define_singleton_method(:status) do
        { "status" => "migration_required", "snapshot_id" => nil }
      end
      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { build.call(bad_status).run! }
      assert_match(/v3 JobStore is not complete/, error.message)

      no_receipt = Object.new
      no_receipt.define_singleton_method(:run!) { |**| true }
      no_receipt.define_singleton_method(:status) do
        {
          "status" => "current",
          "snapshot_id" => "snapshot-#{"b" * 64}"
        }
      end
      no_receipt.define_singleton_method(:completion_receipt) { nil }
      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { build.call(no_receipt).run! }
      assert_match(/completion receipt conflicts/, error.message)
    end
  end

  def test_namespace_and_status_errors_are_typed_at_the_boundary
    with_tmp_dir do |root|
      state = File.join(root, "state")
      FileUtils.mkdir_p(state)
      value = cutover(
        legacy_root: File.join(state, "v2"),
        target_root: File.join(state, "v3"),
        anchor: state
      )

      value.define_singleton_method(:legacy_jobs_type) { :directory }
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { value.ensure_native_namespace! }

      tombstone = Object.new
      tombstone.define_singleton_method(:read) do
        { "origin" => "migrated" }
      end
      value.instance_variable_set(:@tombstone, tombstone)
      value.define_singleton_method(:legacy_jobs_type) { :regular }
      value.define_singleton_method(:completed_migrated_receipt) { |_kind| nil }
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { value.ensure_native_namespace! }

      value.define_singleton_method(:legacy_jobs_type) do
        raise Hive::ConfigError, "unsafe namespace"
      end
      error = assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        value.ensure_native_namespace!
      end
      assert_match(/cannot establish the v3 JobStore namespace/, error.message)

      value.define_singleton_method(:compact_status) do
        raise Hive::RefactorPatrol::JobStore::InconsistentRecord,
              "known inconsistency"
      end
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { value.admission_status }
      value.define_singleton_method(:compact_status) do
        raise Hive::ConfigError, "unsafe admission"
      end
      error = assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        value.admission_status
      end
      assert_match(/cannot inspect the JobStore generation admission/, error.message)

      value.define_singleton_method(:compact_status) do
        raise Hive::ConfigError, "unsafe status"
      end
      error = assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        value.status
      end
      assert_match(/cannot inspect the JobStore generation cutover/, error.message)
    end
  end

  def test_compact_status_preflight_and_prepare_require_claimed_state
    with_tmp_dir do |root|
      state = File.join(root, "state")
      value = cutover(
        legacy_root: File.join(state, "v2"),
        target_root: File.join(state, "v3"),
        anchor: state
      )
      value.define_singleton_method(:legacy_jobs_type) { nil }
      value.define_singleton_method(:target_present?) { true }
      value.define_singleton_method(:recoverable_native_preparation?) { false }
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { value.send(:compact_status) }

      value.define_singleton_method(:read_record) do
        { "status" => "prepared" }
      end
      value.define_singleton_method(:validate_record_tombstone!) { |*| true }
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        value.send(
          :validate_incomplete_migrated_state!,
          { "origin" => "migrated" }
        )
      end

      malformed = cutover(
        legacy_root: File.join(state, "other-v2"),
        target_root: File.join(state, "other-v3"),
        anchor: state,
        nonce: -> { "invalid" }
      )
      malformed.define_singleton_method(:read_record) { nil }
      malformed.define_singleton_method(:target_present?) { false }
      assert_raises(ArgumentError) { malformed.send(:prepare_record) }
    end
  end

  def test_seal_rejects_conflicting_state_and_source_drift
    with_tmp_dir do |root|
      state = File.join(root, "state")
      value = cutover(
        legacy_root: File.join(state, "v2"),
        target_root: File.join(state, "v3"),
        anchor: state
      )
      record = {
        "archive_name" => ".job-schema-v3-source-#{"a" * 32}",
        "transaction_id" => "migration-#{"a" * 32}",
        "status" => "complete",
        "source_inventory_digest" => "b" * 64
      }
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { value.send(:seal_source!, record, kind: :directory) }

      target = Object.new
      target.define_singleton_method(:prepare!) { true }
      value.instance_variable_set(:@target_directory, target)
      value.define_singleton_method(:source_inventory) { |_relative| [ :before ] }
      value.define_singleton_method(:write_record) { |candidate| candidate }
      legacy = Object.new
      legacy.define_singleton_method(:entry_type) { |*, **| :directory }
      value.instance_variable_set(:@legacy_directory, legacy)
      record["status"] = "prepared"
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { value.send(:seal_source!, record, kind: :directory) }

      legacy.define_singleton_method(:entry_type) { |*, **| nil }
      legacy.define_singleton_method(:exchange_directory_with_regular!) { |**| true }
      tombstone = Object.new
      tombstone.define_singleton_method(:write) { |*, **| true }
      tombstone.define_singleton_method(:read) { |*| { "status" => "sealed" } }
      value.instance_variable_set(:@tombstone, tombstone)
      value.define_singleton_method(:sealed_source_inventory) do |_archive|
        [ :after ]
      end
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { value.send(:seal_source!, record, kind: :directory) }
    end
  end

  def test_sealed_namespace_requires_preflight_and_archive
    with_tmp_dir do |root|
      state = File.join(root, "state")
      value = cutover(
        legacy_root: File.join(state, "v2"),
        target_root: File.join(state, "v3"),
        anchor: state
      )
      record = {
        "archive_name" => ".job-schema-v3-source-#{"a" * 32}",
        "transaction_id" => "migration-#{"a" * 32}",
        "status" => "prepared",
        "source_inventory_digest" => "b" * 64
      }
      tombstone = Object.new
      tombstone.define_singleton_method(:read) { { "status" => "sealed" } }
      value.instance_variable_set(:@tombstone, tombstone)
      value.define_singleton_method(:validate_record_tombstone!) { |*| true }
      legacy = Object.new
      legacy.define_singleton_method(:entry_type) { |*, **| nil }
      value.instance_variable_set(:@legacy_directory, legacy)

      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { value.send(:seal_source!, record, kind: :regular) }

      record["status"] = "sealed"
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { value.send(:seal_source!, record, kind: :regular) }
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { value.send(:seal_source!, record, kind: :other) }
    end
  end

  def test_copy_and_tombstone_identity_guards_fail_closed
    with_tmp_dir do |root|
      state = File.join(root, "state")
      value = cutover(
        legacy_root: File.join(state, "v2"),
        target_root: File.join(state, "v3"),
        anchor: state
      )
      inventory = [
        {
          name: "job-1.json",
          bytes: 3,
          digest: "a" * 64,
          mode: 0o600,
          mtime: Time.utc(2026, 7, 10).iso8601(9)
        }
      ]
      record = {
        "archive_name" => ".job-schema-v3-source-#{"a" * 32}",
        "source_inventory_digest" =>
          value.send(:source_inventory_digest, inventory)
      }
      value.define_singleton_method(:sealed_source_inventory) { |_archive| inventory }
      value.define_singleton_method(:source_metadata) { |*, **| :changed }
      legacy = Object.new
      legacy.define_singleton_method(:read_with_metadata) do |*, **|
        {
          bytes: "v2\n",
          mode: 0o600,
          mtime: Time.utc(2026, 7, 10)
        }
      end
      value.instance_variable_set(:@legacy_directory, legacy)
      target = Object.new
      target.define_singleton_method(:read) { |*, **| nil }
      target.define_singleton_method(:ensure_directory) { |_| true }
      target.define_singleton_method(:each_child) { |*, **| [].each }
      value.instance_variable_set(:@target_directory, target)
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { value.send(:copy_sealed_source!, record) }

      tombstone = Object.new
      complete = { "status" => "complete" }
      checked = []
      tombstone.define_singleton_method(:read) { complete }
      tombstone.define_singleton_method(:assert_complete!) do |payload, **|
        checked << payload
        true
      end
      value.instance_variable_set(:@tombstone, tombstone)
      assert_same complete,
                  value.send(
                    :complete_tombstone!,
                    {},
                    snapshot_id: "snapshot-#{"1" * 64}"
                  )
      assert_equal [ complete ], checked

      tombstone.define_singleton_method(:read) do
        { "origin" => "native" }
      end
      value.define_singleton_method(:cutover_record_present?) { true }
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { value.send(:native_tombstone?, :regular) }
      value.define_singleton_method(:cutover_record_present?) { false }
      value.define_singleton_method(:target_present?) { false }
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { value.send(:native_tombstone?, :regular) }

      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        value.send(
          :validate_record_tombstone!,
          {
            "project_id" => "one",
            "transaction_id" => "one",
            "archive_name" => "one",
            "target_schema_version" => 3
          },
          {
            "project_id" => "two",
            "transaction_id" => "two",
            "archive_name" => "two",
            "target_schema_version" => 3
          }
        )
      end
    end
  end

  def test_record_roots_project_and_time_validation_are_strict
    with_tmp_dir do |root|
      state = File.join(root, "state")
      target = File.join(state, "v3")
      legacy = File.join(state, "v2")
      FileUtils.mkdir_p([ target, legacy ])
      value = cutover(
        legacy_root: legacy,
        target_root: target,
        anchor: state
      )
      File.binwrite(
        File.join(
          target,
          Hive::RefactorPatrol::JobStoreGenerationCutover::RECORD_NAME
        ),
        "{"
      )
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        value.send(:read_record)
      end

      valid = {
        "schema" =>
          Hive::RefactorPatrol::JobStoreGenerationCutover::RECORD_SCHEMA,
        "schema_version" => 1,
        "project_id" => "project-demo",
        "source_schema_version" => 2,
        "target_schema_version" => 3,
        "transaction_id" => "migration-#{"a" * 32}",
        "archive_name" => ".job-schema-v3-source-#{"a" * 32}",
        "status" => "prepared",
        "snapshot_id" => nil,
        "migrated_jobs" => nil,
        "source_inventory_digest" => nil,
        "created_at" => Time.utc(2026, 7, 10).iso8601(6),
        "completed_at" => nil
      }
      missing_fetch = Class.new(Hash) do
        def fetch(*)
          raise KeyError, "missing status"
        end
      end.new
      missing_fetch.merge!(valid)
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        value.send(:validate_record!, missing_fetch)
      end

      FileUtils.rm_rf(legacy)
      File.binwrite(legacy, "unsafe")
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        value.send(:legacy_root_present?)
      end
      FileUtils.rm_rf(target)
      File.binwrite(target, "unsafe")
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        value.send(:target_present?)
      end
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        value.send(:timestamp, "not-a-time")
      end
      refute value.send(:valid_timestamp?, "not-a-time")
    end

    assert_raises(ArgumentError) do
      Hive::RefactorPatrol::JobStoreGenerationCutover.new(
        legacy_root: "/tmp/v2",
        target_root: "/tmp/v3",
        target_version: 3,
        validator: Object.new,
        corrupt_record: Hive::RefactorPatrol::JobStore::CorruptRecord,
        inconsistent_record:
          Hive::RefactorPatrol::JobStore::InconsistentRecord,
        project: {},
        anchor: "/tmp",
        writer_fence: NullWriterFence.new
      )
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
              writer_fence: NullWriterFence.new,
              nonce: -> { "a" * 32 })
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
      nonce: nonce,
      migration_factory: migration_factory
    )
  end
end
