require "test_helper"
require "digest"
require "hive/refactor_patrol/job_store"
require_relative "../../fixtures/refactor_patrol/released_v2_job_reader"

class RefactorPatrolJobSchemaRestoreTest < Minitest::Test
  include HiveTestHelper

  NullWriterFence = Data.define do
    def assert_quiescent! = true
  end

  BlockingWriterFence = Data.define do
    def assert_quiescent!
      raise Hive::ConcurrentRunError, "daemon is still live"
    end
  end

  FakeLiveProcess = Struct.new(:pid) do
    def kill(_signal, _pid) = true
  end

  class InventoryDirectory
    attr_reader :root

    def initialize(root, names)
      @root = root
      @names = names
    end

    def each_child(_relative, missing: false)
      return enum_for(__method__, _relative, missing: missing) unless
        block_given?

      @names.each { |name| yield name }
    end
  end

  PROJECT = {
    "name" => "demo",
    "project_id" => "project-demo"
  }.freeze

  def test_explicit_restore_quarantines_the_exact_candidate_and_reopens_with_the_released_v2_reader
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".custom-state")
      source_path = install_released_v2_fixture(project_root, state)
      source_bytes = File.binread(source_path)
      source_mode = 0o640
      source_mtime = Time.at(
        Time.utc(2026, 7, 10, 9, 8, 7).to_i,
        123_456_789,
        :nsec
      ).utc
      File.chmod(source_mode, source_path)
      File.utime(source_mtime, source_mtime, source_path)
      released_artifacts = install_released_v2_artifacts(
        project_root, state
      )
      migrate!(project_root, state)
      root = store_root(project_root, state)
      manifest = JSON.parse(File.binread(File.join(
        root, "job-schema-v2-backup", "manifest.json"
      )))
      assert_equal(
        source_mtime.iso8601(9),
        manifest.fetch("entries").fetch(0).fetch("mtime")
      )
      candidate = tree_snapshot(root)
      assert_path_exists File.join(root, "indexes", "job-query")

      result = Hive::RefactorPatrol::JobStore.restore_schema_v2_snapshot!(
        project_root,
        snapshot_id: manifest.fetch("snapshot_id"),
        hive_state_path: state,
        project: PROJECT,
        writer_fence: NullWriterFence.new
      )

      restored_path = File.join(
        legacy_store_root(project_root, state),
        "jobs",
        "job-released.json"
      )
      assert_equal source_bytes, File.binread(restored_path)
      assert_equal source_mode, File.stat(restored_path).mode & 0o777
      assert_equal source_mtime, File.stat(restored_path).mtime
      assert_equal(
        JSON.parse(source_bytes),
        ReleasedV2JobReader.read(
          project_root, "job-released", hive_state_path: state
        )
      )
      resumed = ReleasedV2JobReader.resume(
        project_root, "job-released", hive_state_path: state
      )
      assert_equal "job-released",
                   resumed.fetch("manifest").fetch("job_id")
      assert_equal(
        released_artifacts,
        released_artifact_snapshots(project_root, state)
      )
      assert_equal candidate, tree_snapshot(result.quarantine_path)
      refute_path_exists root

      assert migrate!(project_root, state)
      fresh_snapshot = File.join(
        root, "job-schema-v2-backup", "manifest.json"
      )
      assert_path_exists fresh_snapshot
      refute File.identical?(
        fresh_snapshot,
        File.join(
          result.quarantine_path,
          "job-schema-v2-backup", "manifest.json"
        )
      )
      assert_equal 3, JSON.parse(
        File.binread(File.join(root, "jobs", "job-released.json"))
      ).fetch("schema_version")

      second_candidate = tree_snapshot(root)
      assert_equal manifest.fetch("snapshot_id"), snapshot_id(root)
      second = restore!(
        project_root, state, manifest.fetch("snapshot_id")
      )
      refute_equal result.quarantine_path, second.quarantine_path
      assert_equal second_candidate, tree_snapshot(second.quarantine_path)

      repeated = restore!(
        project_root, state, manifest.fetch("snapshot_id")
      )
      assert_equal second.quarantine_path, repeated.quarantine_path
    end
  end

  def test_restore_refuses_a_wrong_or_tampered_snapshot_and_preserves_live_state
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      install_released_v2_fixture(project_root, state)
      migrate!(project_root, state)
      root = store_root(project_root, state)
      manifest_path = File.join(
        root, "job-schema-v2-backup", "manifest.json"
      )
      snapshot_id = JSON.parse(File.binread(manifest_path))
                        .fetch("snapshot_id")
      before = tree_snapshot(root)

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        restore!(project_root, state, "snapshot-#{"0" * 64}")
      end
      assert_match(/requested snapshot identity/, error.message)
      assert_equal before, tree_snapshot(root)

      backup = File.join(
        root, "job-schema-v2-backup", "jobs", "job-released.json"
      )
      File.binwrite(backup, "#{File.binread(backup)} ")
      tampered = tree_snapshot(root)
      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { restore!(project_root, state, snapshot_id) }
      assert_match(/snapshot backup digest/, error.message)
      assert_equal tampered, tree_snapshot(root)
    end
  end

  def test_restore_refuses_new_or_changed_v3_jobs_as_lossy
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      install_released_v2_fixture(project_root, state)
      migrate!(project_root, state)
      root = store_root(project_root, state)
      snapshot_id = snapshot_id(root)
      job_path = File.join(root, "jobs", "job-released.json")
      changed = JSON.parse(File.binread(job_path))
      changed["updated_at"] = "2026-07-10T10:02:00Z"
      File.binwrite(job_path, "#{JSON.pretty_generate(changed)}\n")
      before = tree_snapshot(root)

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { restore!(project_root, state, snapshot_id) }
      assert_match(/changed after schema migration/, error.message)
      assert_equal before, tree_snapshot(root)

      FileUtils.rm_rf(project_root)
      FileUtils.mkdir_p(project_root)
      state = File.join(project_root, ".hive-state")
      install_released_v2_fixture(project_root, state)
      migrate!(project_root, state)
      root = store_root(project_root, state)
      snapshot_id = snapshot_id(root)
      existing = JSON.parse(File.binread(File.join(
        root, "jobs", "job-released.json"
      )))
      new_job = existing.merge("job_id" => "job-new")
      File.binwrite(
        File.join(root, "jobs", "job-new.json"),
        "#{JSON.pretty_generate(new_job)}\n"
      )

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { restore!(project_root, state, snapshot_id) }
      assert_match(/exact job name set/, error.message)
    end
  end

  def test_restore_requires_verified_daemon_quiescence_before_touching_state
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      install_released_v2_fixture(project_root, state)
      migrate!(project_root, state)
      root = store_root(project_root, state)
      before = tree_snapshot(root)

      assert_raises(Hive::ConcurrentRunError) do
        Hive::RefactorPatrol::JobStore.restore_schema_v2_snapshot!(
          project_root,
          snapshot_id: snapshot_id(root),
          hive_state_path: state,
          project: PROJECT,
          writer_fence: BlockingWriterFence.new
        )
      end
      assert_equal before, tree_snapshot(root)
    end
  end

  def test_restore_refuses_a_symlinked_quarantine_parent_without_moving_live_state
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      install_released_v2_fixture(project_root, state)
      migrate!(project_root, state)
      root = store_root(project_root, state)
      external = File.join(project_root, "external-quarantine")
      FileUtils.mkdir_p(external)
      quarantine = File.join(
        File.dirname(root), "job-schema-restore-quarantine"
      )
      File.symlink(external, quarantine)
      before = tree_snapshot(root)

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { restore!(project_root, state, snapshot_id(root)) }

      assert_match(/restore storage is unsafe/, error.message)
      assert_equal before, tree_snapshot(root)
      assert_empty Dir.children(external)
      assert File.symlink?(quarantine)
    end
  end

  def test_restore_refuses_a_rebound_transition_lock_without_moving_live_state
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      install_released_v2_fixture(project_root, state)
      migrate!(project_root, state)
      root = store_root(project_root, state)
      lock = File.join(
        File.dirname(root), ".job-schema-transition.lock"
      )
      external = File.join(project_root, "external-transition-lock")
      File.binwrite(external, "external")
      File.unlink(lock)
      File.symlink(external, lock)
      before = tree_snapshot(root)

      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) { restore!(project_root, state, snapshot_id(root)) }

      assert_match(/restore storage is unsafe/, error.message)
      assert_equal before, tree_snapshot(root)
      assert_equal "external", File.binread(external)
      assert File.symlink?(lock)
    end
  end

  def test_restore_requires_every_durable_worker_claim_to_be_quiescent
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      install_released_v2_fixture(project_root, state)
      migrate!(project_root, state)
      root = store_root(project_root, state)
      job_path = File.join(root, "jobs", "job-released.json")
      job = JSON.parse(File.binread(job_path))
      job.fetch("attempts").first["state"] = "running"
      File.binwrite(job_path, "#{JSON.pretty_generate(job)}\n")
      before = tree_snapshot(root)

      error = assert_raises(Hive::ConcurrentRunError) do
        restore!(project_root, state, snapshot_id(root))
      end
      assert_match(/workers must be durably quiescent/, error.message)
      assert_equal before, tree_snapshot(root)
    end
  end

  def test_restore_fence_does_not_treat_the_calling_daemon_as_offline
    with_tmp_dir do |dir|
      pid_file = File.join(dir, "daemon.pid")
      process = FakeLiveProcess.new(4242)
      File.write(
        pid_file,
        {
          "pid" => process.pid,
          "process_start_time" => "boot-4242"
        }.to_yaml
      )
      fence = Hive::RefactorPatrol::MigrationWriterFence.new(
        pid_file: pid_file,
        process: process,
        allow_current_process: false,
        operation: "JobStore schema restore"
      )

      with_replaced_singleton_method(
        Hive::Lock, :process_start_time, ->(*) { "boot-4242" }
      ) do
        error = assert_raises(Hive::ConcurrentRunError) do
          fence.assert_quiescent!
        end
        assert_match(/before JobStore schema restore/, error.message)
      end
    end
  end

  def test_restore_fence_rejects_a_reused_pid_and_malformed_pid_payload
    with_tmp_dir do |dir|
      pid_file = File.join(dir, "daemon.pid")
      process = FakeLiveProcess.new(4_242)
      File.write(
        pid_file,
        {
          "pid" => process.pid,
          "process_start_time" => "recorded-start"
        }.to_yaml
      )
      fence = Hive::RefactorPatrol::MigrationWriterFence.new(
        pid_file: pid_file,
        process: process,
        operation: "JobStore migration"
      )

      with_replaced_singleton_method(
        Hive::Lock,
        :process_start_time,
        ->(*) { "different-start" }
      ) do
        error = assert_raises(Hive::ConcurrentRunError) do
          fence.assert_quiescent!
        end
        assert_match(/cannot verify the live Hive daemon/, error.message)
      end

      File.write(pid_file, { "pid" => "not-an-integer" }.to_yaml)
      error = assert_raises(Hive::ConcurrentRunError) do
        fence.assert_quiescent!
      end
      assert_match(/cannot verify the Hive daemon writer fence/, error.message)
    end
  end

  def test_schema_status_is_a_descriptor_safe_full_tree_read
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      install_released_v2_fixture(project_root, state)
      root = legacy_store_root(project_root, state)
      before = tree_snapshot(root)

      status = Hive::RefactorPatrol::JobStore.schema_status(
        project_root, hive_state_path: state, project: PROJECT
      )

      assert_equal "migration_required", status.fetch("status")
      assert_nil status.fetch("snapshot_id")
      assert_equal before, tree_snapshot(root)
      refute_path_exists File.join(
        root, "jobs", "job-released.json.lock"
      )
    end
  end

  def test_restore_inventory_accepts_jobs_with_paired_persistent_locks
    names = 4_097.times.flat_map do |index|
      name = format("job-%04d.json", index)
      [ name, "#{name}.lock" ]
    end
    restore = Hive::RefactorPatrol::JobSchemaRestore.new(
      target_root: "/tmp/hive-restore-inventory/v3",
      legacy_root: "/tmp/hive-restore-inventory/v2",
      target_version: 3,
      validator: Object.new,
      corrupt_record: Hive::RefactorPatrol::JobStore::CorruptRecord,
      inconsistent_record:
        Hive::RefactorPatrol::JobStore::InconsistentRecord,
      project_id: "project-demo",
      writer_fence: NullWriterFence.new
    )
    restore.instance_variable_set(
      :@directory,
      InventoryDirectory.new(
        "/tmp/hive-restore-inventory/v3",
        names
      )
    )

    inventory = restore.send(:candidate_job_inventory)
    assert_equal names.sort,
                 restore.send(:inventory_names, inventory)
  end

  def test_restore_rejects_unsafe_candidate_and_quarantine_inventory_shapes
    with_tmp_dir do |root|
      target = File.join(root, "v3")
      legacy = File.join(root, "v2")
      restore = schema_restore(target, legacy, anchor: root)
      unsafe = File.join(root, "unsafe-generation")
      File.binwrite(unsafe, "not a directory")
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        restore.send(:safe_directory?, unsafe)
      end

      transition = Object.new
      transition.define_singleton_method(:each_child) do |*, **|
        [ "invalid" ].each
      end
      restore.instance_variable_set(:@transition_directory, transition)
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        restore.send(
          :select_quarantined_candidate!,
          "snapshot-#{"1" * 64}"
        )
      end

      transaction = "migration-#{"2" * 32}"
      transition.define_singleton_method(:each_child) do |*, **|
        [ transaction ].each
      end
      transition.define_singleton_method(:entry_type) { |*| :regular }
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        restore.send(
          :select_quarantined_candidate!,
          "snapshot-#{"1" * 64}"
        )
      end

      transition.define_singleton_method(:entry_type) { |*| :directory }
      restore.define_singleton_method(:read_cutover_record) { |_path| {} }
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        restore.send(
          :select_quarantined_candidate!,
          "snapshot-#{"1" * 64}"
        )
      end
    end
  end

  def test_restore_translates_quarantine_ordering_and_cutover_parse_failures
    with_tmp_dir do |root|
      target = File.join(root, "v3")
      legacy = File.join(root, "v2")
      restore = schema_restore(target, legacy, anchor: root)
      transaction = "migration-#{"2" * 32}"
      transition = Object.new
      transition.define_singleton_method(:each_child) do |*, **|
        [ transaction ].each
      end
      transition.define_singleton_method(:entry_type) { |*| :directory }
      restore.instance_variable_set(:@transition_directory, transition)
      restore.define_singleton_method(:valid_cutover_record_shape?) do |_record|
        true
      end
      restore.define_singleton_method(:read_cutover_record) do |_path|
        {
          "snapshot_id" => "snapshot-#{"1" * 64}",
          "transaction_id" => transaction
        }
      end
      error = assert_raises(
        Hive::RefactorPatrol::JobStore::CorruptRecord
      ) do
        restore.send(
          :select_quarantined_candidate!,
          "snapshot-#{"1" * 64}"
        )
      end
      assert_match(/quarantine inventory is malformed/, error.message)

      candidate = File.join(root, "candidate")
      FileUtils.mkdir_p(candidate)
      record_path = File.join(
        candidate,
        Hive::RefactorPatrol::JobStoreGenerationCutover::RECORD_NAME
      )
      File.binwrite(record_path, JSON.pretty_generate("record" => true))
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        schema_restore(target, legacy, anchor: root).send(
          :read_cutover_record,
          candidate
        )
      end
      File.binwrite(record_path, "{")
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        schema_restore(target, legacy, anchor: root).send(
          :read_cutover_record,
          candidate
        )
      end
      refute schema_restore(target, legacy, anchor: root).send(
        :valid_cutover_record_shape?,
        nil
      )
    end
  end

  def test_restore_candidate_validation_rejects_ledger_version_and_missing_fields
    with_tmp_dir do |root|
      restore = schema_restore(
        File.join(root, "v3"),
        File.join(root, "v2"),
        anchor: root
      )
      restore.instance_variable_set(:@candidate_root, File.join(root, "v3"))
      manifest = {
        "entries" => [
          {
            "name" => "job-1.json",
            "digest" => "1" * 64
          }
        ]
      }
      restore.define_singleton_method(:validate_completion_marker!) { |_| true }
      restore.define_singleton_method(:validate_cutover_record!) { |_| true }
      restore.define_singleton_method(:capture_candidate_jobs) do
        [
          {
            name: "job-1.json",
            data: {},
            bytes: "{}\n",
            version: 3
          }
        ]
      end
      restore.define_singleton_method(:conversion_records) { {} }
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { restore.send(:validate_candidate!, manifest) }

      source = "{\"job_id\":\"job-1\"}"
      snapshot = Object.new
      snapshot.define_singleton_method(:backup_bytes) { |_entry| source }
      restore.instance_variable_set(:@snapshot_store, snapshot)
      restore.define_singleton_method(:conversion_records) do
        { "job-1.json" => "{}" }
      end
      restore.define_singleton_method(:capture_candidate_jobs) do
        [
          {
            name: "job-1.json",
            data: {},
            bytes: "{}\n",
            version: 2
          }
        ]
      end
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) { restore.send(:validate_candidate!, manifest) }

      missing_restore = schema_restore(
        File.join(root, "missing-v3"),
        File.join(root, "missing-v2"),
        anchor: root
      )
      directory = Object.new
      directory.define_singleton_method(:read_with_metadata) do |*, **|
        { bytes: "{\"job_id\":\"job-1\"}" }
      end
      missing_restore.instance_variable_set(:@directory, directory)
      missing_restore.define_singleton_method(:candidate_job_inventory) do
        :inventory
      end
      missing_restore.define_singleton_method(:inventory_names) do |_inventory|
        [ "job-1.json" ]
      end
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        missing_restore.send(:capture_candidate_jobs)
      end
    end
  end

  def test_restore_rejects_conversion_archive_and_stage_namespace_conflicts
    with_tmp_dir do |root|
      restore = schema_restore(
        File.join(root, "v3"),
        File.join(root, "v2"),
        anchor: root
      )
      candidate = Object.new
      candidate.define_singleton_method(:each_child) do |*, **|
        [ "invalid" ].each
      end
      restore.instance_variable_set(:@directory, candidate)
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        restore.send(:conversion_records)
      end

      legacy = Object.new
      legacy.define_singleton_method(:entry_type) { |*, **| nil }
      restore.instance_variable_set(:@legacy_directory, legacy)
      payload = { "archive_name" => ".job-schema-v3-source-#{"1" * 32}" }
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        restore.send(
          :validate_sealed_archive!,
          { "entries" => [] },
          payload
        )
      end

      legacy.define_singleton_method(:entry_type) { |*, **| :directory }
      legacy.define_singleton_method(:each_child) { |*| [ "wrong.json" ].each }
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        restore.send(
          :validate_sealed_archive!,
          { "entries" => [ { "name" => "job-1.json" } ] },
          payload
        )
      end

      legacy.define_singleton_method(:entry_type) { |*, **| :regular }
      restore.define_singleton_method(:candidate_transaction_id) do
        "migration-#{"2" * 32}"
      end
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        restore.send(
          :build_restore_stage!,
          { "entries" => [] }
        )
      end

      legacy.define_singleton_method(:entry_type) { |*, **| :directory }
      legacy.define_singleton_method(:each_child) { |*| [ "bad" ].each }
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        restore.send(
          :build_restore_stage!,
          { "entries" => [ { "name" => "bad" } ] }
        )
      end
    end
  end

  def test_restore_reuses_a_verified_stage_and_rejects_activation_and_quarantine_drift
    with_tmp_dir do |root|
      target = File.join(root, "v3")
      restore = schema_restore(
        target,
        File.join(root, "v2"),
        anchor: root
      )
      entry = {
        "name" => "job-1.json",
        "bytes" => 3,
        "digest" => Digest::SHA256.hexdigest("v2\n"),
        "mode" => 0o600,
        "mtime" => Time.utc(2026, 7, 10, 12).iso8601(9)
      }
      legacy = Object.new
      legacy.define_singleton_method(:entry_type) { |*, **| :directory }
      legacy.define_singleton_method(:each_child) do |*|
        [ "job-1.json" ].each
      end
      legacy.define_singleton_method(:read_with_metadata) do |*, **|
        {
          bytes: "v2\n",
          mode: 0o600,
          mtime: Time.utc(2026, 7, 10, 12)
        }
      end
      restore.instance_variable_set(:@legacy_directory, legacy)
      restore.define_singleton_method(:candidate_transaction_id) do
        "migration-#{"2" * 32}"
      end
      verified = []
      restore.define_singleton_method(:verify_v2_snapshot!) do |*arguments|
        verified << arguments
        true
      end

      restore.send(:build_restore_stage!, { "entries" => [ entry ] })
      assert_equal 1, verified.size

      restore.define_singleton_method(:restored_namespace_active?) { false }
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        restore.send(
          :validate_restored_namespace!,
          { "entries" => [] }
        )
      end

      restore.instance_variable_set(:@candidate_root, File.join(root, "other"))
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        restore.send(
          :quarantine_candidate!,
          "snapshot-#{"1" * 64}"
        )
      end
    end
  end

  def test_restore_record_parsing_filename_and_error_paths_are_explicit
    with_tmp_dir do |root|
      target = File.join(root, "v3")
      restore = schema_restore(
        target,
        File.join(root, "v2"),
        anchor: root
      )
      restore.instance_variable_set(:@candidate_root, target)

      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        restore.send(:parse_object, "{", "jobs/job-1.json")
      end
      assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        restore.send(
          :validate_filename!,
          "job-1.json",
          { "job_id" => "job-2" }
        )
      end

      [ "/absolute", "relative", nil ].each do |relative|
        error = assert_raises(
          Hive::RefactorPatrol::JobStore::CorruptRecord
        ) do
          restore.send(:corrupt!, "corrupt", relative)
        end
        assert_match(/corrupt/, error.message)
      end
      [ "/absolute", "relative" ].each do |relative|
        error = assert_raises(
          Hive::RefactorPatrol::JobStore::InconsistentRecord
        ) do
          restore.send(:inconsistent!, "inconsistent", relative)
        end
        assert_match(/inconsistent/, error.message)
      end
    end
  end

  private

  def schema_restore(target_root, legacy_root, anchor:)
    Hive::RefactorPatrol::JobSchemaRestore.new(
      target_root: target_root,
      legacy_root: legacy_root,
      target_version: 3,
      validator: Hive::RefactorPatrol::JobRecordValidator.new(
        contract: Hive::RefactorPatrol::JobStore
      ),
      corrupt_record: Hive::RefactorPatrol::JobStore::CorruptRecord,
      inconsistent_record:
        Hive::RefactorPatrol::JobStore::InconsistentRecord,
      project_id: "project-demo",
      anchor: anchor,
      writer_fence: NullWriterFence.new
    )
  end

  def fixture_path
    File.expand_path(
      "../../fixtures/refactor_patrol/released_v2_job.json", __dir__
    )
  end

  def install_released_v2_fixture(project_root, state)
    path = File.join(
      state, "refactor_patrol", "v2", "jobs", "job-released.json"
    )
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, File.binread(fixture_path))
    path
  end

  def migrate!(project_root, state)
    Hive::RefactorPatrol::JobStore.migrate_schema!(
      project_root,
      hive_state_path: state,
      project: PROJECT,
      writer_fence: NullWriterFence.new
    )
  end

  def install_released_v2_artifacts(project_root, state)
    root = legacy_store_root(project_root, state)
    artifacts = {
      "manifests/job-released.json" =>
        "#{JSON.generate("job_id" => "job-released", "pr" => 7)}\n",
      "families/family-a.json" =>
        "#{JSON.generate("family_id" => "family-a")}\n",
      "results/job-released.json" =>
        "#{JSON.generate("job_id" => "job-released", "status" => "done")}\n",
      "indexes/fingerprints.json" =>
        "#{JSON.generate("schema" => "released-v2-fingerprints")}\n",
      "indexes/actions.json" =>
        "#{JSON.generate("schema" => "released-v2-actions")}\n",
      "runs/logs/job-released.log" => "released v2 workflow log\n"
    }
    mtime = Time.utc(2026, 7, 9, 8, 7, 6, 654_321)
    artifacts.each_with_index do |(relative, bytes), index|
      path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)
      File.chmod(index.even? ? 0o640 : 0o600, path)
      File.utime(mtime, mtime, path)
    end
    released_artifact_snapshots(project_root, state)
  end

  def released_artifact_snapshots(project_root, state)
    root = legacy_store_root(project_root, state)
    %w[
      manifests/job-released.json
      families/family-a.json
      results/job-released.json
      indexes/fingerprints.json
      indexes/actions.json
      runs/logs/job-released.log
    ].to_h do |relative|
      path = File.join(root, relative)
      stat = File.lstat(path)
      [
        relative,
        [ File.binread(path), stat.mode & 0o777, stat.mtime ]
      ]
    end
  end

  def restore!(project_root, state, snapshot)
    Hive::RefactorPatrol::JobStore.restore_schema_v2_snapshot!(
      project_root,
      snapshot_id: snapshot,
      hive_state_path: state,
      project: PROJECT,
      writer_fence: NullWriterFence.new
    )
  end

  def store_root(project_root, state)
    Hive::RefactorPatrol::JobStore.root_for(
      project_root, hive_state_path: state
    )
  end

  def legacy_store_root(project_root, state)
    Hive::RefactorPatrol::JobStore.legacy_root_for(
      project_root, hive_state_path: state
    )
  end

  def snapshot_id(root)
    JSON.parse(File.binread(File.join(
      root, "job-schema-v2-backup", "manifest.json"
    ))).fetch("snapshot_id")
  end

  def tree_snapshot(root)
    Dir.glob(
      File.join(root, "**", "*"), File::FNM_DOTMATCH
    ).sort.to_h do |path|
      relative = path.delete_prefix("#{root}/")
      stat = File.lstat(path)
      value = if stat.file?
        [ :file, stat.mode & 0o777, stat.mtime, File.binread(path) ]
      elsif stat.directory?
        [ :directory, stat.mode & 0o777, stat.mtime ]
      else
        [ :other, stat.mode, stat.mtime ]
      end
      [ relative, value ]
    end
  end
end
