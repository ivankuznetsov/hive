require "test_helper"
require "digest"
require "json"
require "hive/attempts/store"
require "hive/daemon/dispatch_request_queue"
require "hive/daemon/dispatch_result_queue"
require "hive/recovery/migration"

class RecoveryMigrationTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 25, 12, 0, 0)

  def test_new_default_store_creates_v3_and_the_v2_fence
    with_tmp_dir do |state_home|
      with_env("HIVE_HOME" => state_home) do
        store = Hive::Attempts::Store.new
        assert_equal File.join(state_home, "attempts", "v3"), store.root
        assert File.directory?(store.records_root)
        status = store.storage_health.snapshot(hot_count: 0, invalid_hot_count: 0)
        assert_equal "complete", status.dig("layout", "migration")
        assert_equal 0, status.dig("layout", "last_result", "source_count")
      end

      assert_equal fence_payload, read_json(File.join(state_home, "attempts", "v2"))
      assert_equal 0o600, File.stat(File.join(state_home, "attempts", "v2")).mode & 0o777
      assert_path_exists File.join(state_home, "recovery-migration-v4.json")
    end
  end

  def test_completed_default_store_reopens_without_enumerating_cold_state
    with_tmp_dir do |state_home|
      with_env("HIVE_HOME" => state_home) { Hive::Attempts::Store.new }
      attempts_root = File.join(state_home, "attempts", "v3")
      original = Dir.method(:children)
      Dir.singleton_class.define_method(:children) do |path|
        raise "enumerated cold attempt state" if File.expand_path(path).start_with?(attempts_root)

        original.call(path)
      end

      begin
        with_env("HIVE_HOME" => state_home) do
          assert_equal attempts_root, Hive::Attempts::Store.new.root
        end
      ensure
        Dir.singleton_class.define_method(:children, original)
      end
    end
  end

  def test_default_store_cuts_over_and_keeps_terminal_hot_until_journal_delivery
    with_tmp_dir do |state_home|
      record = terminal_attempt(current_attempt(attempt_id: "terminal"))
      write_v2_record(state_home, record)
      hot_log = File.join(state_home, "attempts", "v2", "logs", "terminal.frames")
      FileUtils.mkdir_p(File.dirname(hot_log))
      File.binwrite(hot_log, "frame\n")

      with_env("HIVE_HOME" => state_home) do
        store = Hive::Attempts::Store.new
        assert_equal record, store.fetch("terminal").to_h
        assert_equal record, store.fetch_hot("terminal").to_h
        assert_path_exists store.permanent_proofs.path_for("terminal")
        assert_equal "frame\n", File.binread(store.log_archive.hot_path("terminal"))
        refute_path_exists store.log_archive.cold_path("terminal")
        status = store.storage_health.snapshot(hot_count: 1, invalid_hot_count: 0)
        assert_equal 0, status.dig("layout", "last_result", "promoted")
      end

      assert File.file?(File.join(state_home, "attempts", "v2"))
      assert File.directory?(File.join(state_home, "attempts", "v3"))
    end
  end

  def test_explicit_custom_store_root_does_not_migrate
    with_tmp_dir do |state_home|
      custom = File.join(state_home, "custom-attempts")
      with_env("HIVE_HOME" => state_home) do
        assert_equal custom, Hive::Attempts::Store.new(root: custom).root
      end
      refute_path_exists File.join(state_home, "attempts")
      refute_path_exists File.join(state_home, "recovery-migration-v4.json")
    end
  end

  def test_open_default_uses_the_supplied_state_home
    with_tmp_dir do |root|
      state_home = File.join(root, "daemon-home")
      store = Hive::Attempts::Store.open_default(state_home: state_home)

      assert_equal File.join(state_home, "attempts", "v3"), store.root
      assert_equal fence_payload, read_json(File.join(state_home, "attempts", "v2"))
    end
  end

  def test_refuses_a_live_attempt_or_held_writer_lock
    with_tmp_dir do |state_home|
      write_v2_record(state_home, current_attempt(attempt_id: "live"))
      error = assert_raises(Hive::Recovery::Migration::Error) do
        migrate(state_home)
      end
      assert_includes error.message, "live attempt live"
      assert_path_exists File.join(state_home, "attempts", "v2")
      refute_path_exists File.join(state_home, "attempts", "v3")
    end

    with_tmp_dir do |state_home|
      write_v2_record(state_home, lost_attempt(current_attempt(attempt_id: "lost")))
      lock_path = File.join(state_home, "attempts", "v2", "generation-locks", "admission.lock")
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
        assert_includes error.message, "active attempt writer"
      end
      assert_path_exists File.join(state_home, "attempts", "v2", "records", "lost.json")
    end
  end

  def test_refuses_mixed_roots_symlinks_and_fence_collisions
    with_tmp_dir do |state_home|
      write_v2_record(state_home, lost_attempt(current_attempt(attempt_id: "old")))
      current = File.join(state_home, "attempts", "v3", "records")
      FileUtils.mkdir_p(current)
      write_json(File.join(current, "current.json"), lost_attempt(current_attempt(attempt_id: "current")))

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "both attempts/v2 and attempts/v3 contain material state"
      assert_path_exists File.join(state_home, "attempts", "v2", "records", "old.json")
      assert_path_exists File.join(current, "current.json")
    end

    with_tmp_dir do |state_home|
      attempts = File.join(state_home, "attempts")
      target = File.join(state_home, "target")
      FileUtils.mkdir_p([ attempts, target ])
      File.symlink(target, File.join(attempts, "v2"))
      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "fence is not a real regular file"
      assert File.symlink?(File.join(attempts, "v2"))
    end

    with_tmp_dir do |state_home|
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v3"))
      collision = File.join(state_home, "attempts", "v2")
      File.binwrite(collision, "operator data")
      File.chmod(0o600, collision)
      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "fence is invalid or colliding"
      assert_equal "operator data", File.binread(File.join(state_home, "attempts", "v2"))
    end
  end

  def test_refuses_unsafe_lock_current_root_and_state_home_paths
    with_tmp_dir do |state_home|
      target = File.join(state_home, "lock-target")
      File.write(target, "lock")
      File.symlink(target, File.join(state_home, ".recovery-migration-v2.lock"))

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "migration lock is a symlink"
    end

    with_tmp_dir do |state_home|
      current = File.join(state_home, "attempts", "v3")
      FileUtils.mkdir_p(File.dirname(current))
      File.write(current, "not a directory")

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "attempts/v3 path is not a real directory"
    end

    with_tmp_dir do |root|
      target = File.join(root, "real-state-home")
      linked = File.join(root, "linked-state-home")
      FileUtils.mkdir_p(target)
      File.symlink(target, linked)

      error = assert_raises(Hive::Recovery::Migration::Error) do
        Hive::Recovery::Migration.ensure!(state_home: linked, now: NOW)
      end
      assert_includes error.message, "migration directory"
      assert_includes error.message, "is not a real directory"
    end

    with_tmp_dir do |state_home|
      actual_euid = Process.euid
      with_replaced_singleton_method(Process, :euid, -> { actual_euid + 1 }) do
        error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
        assert_includes error.message, "attempt state has the wrong owner"
      end
    end
  end

  def test_completed_layout_revalidates_fence_root_and_checkpoint
    with_tmp_dir do |state_home|
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v3"))
      write_receipt_marker(state_home)

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "old-binary fence is missing"
    end

    with_tmp_dir do |state_home|
      target = File.join(state_home, "v3-target")
      FileUtils.mkdir_p(target)
      write_fence(state_home)
      File.symlink(target, File.join(state_home, "attempts", "v3"))
      write_receipt_marker(state_home)

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "attempt root"
      assert_includes error.message, "is not a real directory"
    end

    with_tmp_dir do |state_home|
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v3"))
      write_fence(state_home)
      write_receipt_marker(state_home)
      write_checkpoint(state_home, phase: "fenced")

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "cutover checkpoint is incomplete"
    end
  end

  def test_refuses_wrong_fence_mode_and_valid_json_collision
    with_tmp_dir do |state_home|
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v3"))
      fence = write_fence(state_home)
      File.chmod(0o644, fence)

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "fence mode must be 0600"
    end

    with_tmp_dir do |state_home|
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v3"))
      write_fence(state_home, { "schema" => "operator-data" })

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "fence is invalid or colliding"
    end
  end

  def test_refuses_unknown_non_record_and_non_regular_layout_entries
    with_tmp_dir do |state_home|
      records = File.join(state_home, "attempts", "v2", "records")
      FileUtils.mkdir_p(records)
      File.write(File.join(records, "notes.txt"), "not an attempt")

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "attempt records contain a non-record entry"
    end

    with_tmp_dir do |state_home|
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v2", "unexpected"))

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "unknown layout entries: unexpected"
    end

    with_tmp_dir do |state_home|
      outputs = File.join(state_home, "attempts", "v2", "outputs")
      FileUtils.mkdir_p(outputs)
      File.mkfifo(File.join(outputs, "writer.pipe"), 0o600)

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "attempt tree contains a non-regular entry"
    end
  end

  def test_detects_scan_and_checkpoint_corpus_changes
    with_tmp_dir do |state_home|
      write_v2_record(state_home, terminal_attempt(current_attempt(attempt_id: "terminal")))
      original = Hive::Attempts::Store.instance_method(:scan)
      replaced = false
      replacement = lambda do
        if !replaced && instance_variable_get(:@root).end_with?("/attempts/v2")
          replaced = true
          Hive::Attempts::Scan.new(records: [], invalid_records: [])
        else
          original.bind_call(self)
        end
      end

      with_replaced_instance_method(Hive::Attempts::Store, :scan, replacement) do
        error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
        assert_includes error.message, "source corpus changed"
      end
      assert_path_exists File.join(state_home, "attempts", "v2", "records", "terminal.json")
    end

    with_tmp_dir do |state_home|
      current = File.join(state_home, "attempts", "v3", "records")
      FileUtils.mkdir_p(current)
      write_json(
        File.join(current, "terminal.json"),
        terminal_attempt(current_attempt(attempt_id: "terminal"))
      )
      write_fence(state_home)
      write_checkpoint(
        state_home, phase: "fenced", source_count: 1,
        source_valid_count: 1, source_digest: "0" * 64
      )

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "does not match its cutover checkpoint"
    end
  end

  def test_refuses_material_and_raced_obsolete_v1_state
    with_tmp_dir do |state_home|
      legacy = File.join(state_home, "attempts", "v1")
      FileUtils.mkdir_p(legacy)
      File.write(File.join(legacy, "state.json"), "{}")

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
      assert_includes error.message, "unsupported attempts/v1 state remains"
      assert_path_exists File.join(legacy, "state.json")
    end

    with_tmp_dir do |state_home|
      records = File.join(state_home, "attempts", "v1", "records")
      FileUtils.mkdir_p(records)
      original = Dir.method(:rmdir)
      injected = false
      replacement = lambda do |path|
        if !injected && path == records
          File.write(File.join(records, "late-state"), "preserve")
          injected = true
        end
        original.call(path)
      end

      with_replaced_singleton_method(Dir, :rmdir, replacement) do
        error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
        assert_includes error.message, "changed while it was being checked"
      end
      assert_equal "preserve", File.read(File.join(records, "late-state"))
    end
  end

  def test_empty_v2_skeleton_race_preserves_both_roots
    with_tmp_dir do |state_home|
      records = File.join(state_home, "attempts", "v2", "records")
      FileUtils.mkdir_p(records)
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v3"))
      original = Dir.method(:rmdir)
      injected = false
      replacement = lambda do |path|
        if !injected && path == records
          File.write(File.join(records, "late-state"), "preserve")
          injected = true
        end
        original.call(path)
      end

      with_replaced_singleton_method(Dir, :rmdir, replacement) do
        error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
        assert_includes error.message, "both attempts/v2 and attempts/v3 contain material state"
      end
      assert_equal "preserve", File.read(File.join(records, "late-state"))
      assert File.directory?(File.join(state_home, "attempts", "v3"))
    end
  end

  def test_prunes_an_empty_old_skeleton_and_normalizes_private_modes
    with_tmp_dir do |state_home|
      current = File.join(state_home, "attempts", "v3")
      FileUtils.mkdir_p(File.join(current, "records"))
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v2", "records"))
      File.chmod(0o755, current)
      File.chmod(0o755, File.join(current, "records"))

      migrate(state_home)

      assert_equal fence_payload, read_json(File.join(state_home, "attempts", "v2"))
      assert_equal 0o700, File.stat(current).mode & 0o777
      assert_equal 0o700, File.stat(File.join(current, "records")).mode & 0o777
    end
  end

  def test_prunes_an_empty_v1_skeleton_before_v2_cutover
    with_tmp_dir do |state_home|
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v1", "records", "empty"))
      write_v2_record(state_home, terminal_attempt(current_attempt(attempt_id: "terminal")))

      result = migrate(state_home)

      assert_equal 1, result.dig("attempts", "promoted")
      refute_path_exists File.join(state_home, "attempts", "v1")
      assert_equal fence_payload, read_json(File.join(state_home, "attempts", "v2"))
    end
  end

  def test_rejects_old_attempt_record_schemas_without_rewriting_them
    [ 1, 2 ].each do |version|
      with_tmp_dir do |state_home|
        data = current_attempt(attempt_id: "schema-#{version}").merge("schema_version" => version)
        write_v2_record(state_home, data)

        error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
        assert_includes error.message, "only schema v3"
        assert_equal version, read_json(
          File.join(state_home, "attempts", "v2", "records", "schema-#{version}.json")
        ).fetch("schema_version")
      end
    end
  end

  def test_rejects_valid_json_that_is_not_an_attempt_record
    with_tmp_dir do |state_home|
      path = File.join(state_home, "attempts", "v2", "records", "not-record.json")
      write_json(path, [ "not", "an", "attempt" ])

      error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }

      assert_includes error.message, "not an attempt record object"
      assert_equal [ "not", "an", "attempt" ], read_json(path)
    end
  end

  def test_incomplete_journal_delivery_keeps_historical_final_hot
    with_tmp_dir do |state_home|
      write_v2_record(state_home, terminal_attempt(current_attempt(attempt_id: "terminal")))
      observer = Object.new
      observer.define_singleton_method(:observe) { |_status, now:| :pending }
      factory = lambda do |store:, state_home:|
        Hive::Attempts::FinalizationMaintenance.new(
          store: store, condition_observer: observer,
          delivery_pending: ->(_record) { false }
        )
      end

      result = with_replaced_singleton_method(
        Hive::Attempts::FinalizationMaintenance, :runtime, factory
      ) do
        Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
      end
      store = Hive::Attempts::Store.new(
        root: File.join(state_home, "attempts", "v3"), create_directories: false
      )

      assert_equal 0, result.dig("attempts", "promoted")
      assert store.fetch_hot("terminal")
      pending = store.pending_finalizations.fetch("terminal")
      assert_equal false, pending.dig("consumers", "journal")
      assert_equal true, pending.dig("consumers", "request_delivery")
    end
  end

  def test_keeps_unresolved_and_invalid_records_hot_but_promotes_resolved_history
    with_tmp_dir do |state_home|
      terminal = terminal_attempt(current_attempt(attempt_id: "terminal"))
      unresolved = lost_attempt(current_attempt(attempt_id: "unresolved"))
      resolved = lost_attempt(current_attempt(attempt_id: "resolved", generation: "lineage"))
      successor = terminal_attempt(current_attempt(
        attempt_id: "successor", generation: "lineage", predecessor_attempt_id: "resolved"
      ), outcome: "failed", exit_status: 1)
      [ terminal, unresolved, resolved, successor ].each { |record| write_v2_record(state_home, record) }
      write_resolved_outcome(state_home, resolved, successor)
      invalid = File.join(state_home, "attempts", "v2", "records", "invalid.json")
      File.binwrite(invalid, "{")

      migrate(state_home)
      store = Hive::Attempts::Store.new(
        root: File.join(state_home, "attempts", "v3"), create_directories: false
      )

      assert_nil store.fetch_hot("terminal")
      assert_nil store.fetch_hot("resolved")
      assert_nil store.fetch_hot("successor")
      assert_equal "lost", store.fetch_hot("unresolved").state
      assert_path_exists File.join(store.records_root, "invalid.json")
      assert_equal 1, store.scan.invalid_records.size
      %w[terminal resolved successor].each { |id| assert store.permanent_proofs.fetch(id) }
    end
  end

  def test_small_deterministic_corpus_records_exact_parity_receipt
    with_tmp_dir do |state_home|
      48.times do |index|
        id = format("attempt-%02d", index)
        record = current_attempt(
          attempt_id: id, generation: "generation-#{index % 12}",
          accepted_at: NOW + index
        )
        record = if (index % 4).zero?
          lost_attempt(record).tap do |lost|
            if index.zero?
              lost["worker"] = {
                "pid" => Process.pid, "start_fingerprint" => "start",
                "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp
              }
            end
          end
        else
          terminal_attempt(record, outcome: index.even? ? "failed" : "succeeded", exit_status: index.even? ? 1 : 0)
        end
        write_v2_record(state_home, record)
      end

      result = migrate(state_home)
      checkpoint = read_json(File.join(state_home, "attempts", ".v3-cutover.json"))

      assert_equal 48, result.dig("attempts", "source_count")
      assert_operator result.dig("attempts", "decision_count"), :>, 0
      assert_match(/\A[0-9a-f]{64}\z/, result.dig("attempts", "decision_digest"))
      assert_equal result.dig("attempts", "decision_digest"), checkpoint.fetch("decision_digest")
      assert_equal 12, result.dig("attempts", "hot")
    end
  end

  def test_blocks_hot_removal_when_generated_indexes_do_not_match_the_scan
    with_tmp_dir do |state_home|
      write_v2_record(state_home, terminal_attempt(current_attempt(attempt_id: "terminal")))
      original = Hive::Attempts::DecisionIndex.instance_method(:terminal_attempt_id)
      with_replaced_instance_method(
        Hive::Attempts::DecisionIndex, :terminal_attempt_id,
        ->(**) { "wrong-attempt" }
      ) do
        error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
        assert_includes error.message, "index parity mismatch"
      end
      Hive::Attempts::DecisionIndex.define_method(:terminal_attempt_id, original)

      assert_path_exists File.join(state_home, "attempts", "v3", "records", "terminal.json")
      refute_path_exists File.join(state_home, "recovery-migration-v4.json")
      failed_store = Hive::Attempts::Store.new(
        root: File.join(state_home, "attempts", "v3"), create_directories: false
      )
      failed = failed_store.storage_health.snapshot(hot_count: 1, invalid_hot_count: 0)
      assert_equal "degraded", failed.fetch("status")
      assert_equal "migration_failed", failed.fetch("degraded_reason")

      migrate(state_home)
      recovered = failed_store.storage_health.snapshot(hot_count: 0, invalid_hot_count: 0)
      assert_equal "healthy", recovered.fetch("status")
      assert_nil recovered.fetch("degraded_reason")
    end
  end

  def test_crash_boundaries_resume_without_losing_the_source
    %i[rename fence index proof log hot_removal].each do |boundary|
      with_tmp_dir do |state_home|
        write_v2_record(state_home, terminal_attempt(current_attempt(attempt_id: "terminal")))
        inject_after(boundary, state_home) do
          assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
        end

        result = migrate(state_home)
        store = Hive::Attempts::Store.new(root: File.join(state_home, "attempts", "v3"))
        assert_equal 1, result.dig("attempts", "source_count"), boundary
        assert_equal 1, result.dig("attempts", "promoted"), boundary
        assert store.permanent_proofs.fetch("terminal"), boundary
        assert_nil store.fetch_hot("terminal"), boundary
        assert_equal fence_payload, read_json(File.join(state_home, "attempts", "v2")), boundary
      rescue Hive::Recovery::Migration::Error => error
        flunk "#{boundary}: #{error.message}"
      end
    end
  end

  def test_queue_schema_migration_remains_unchanged
    with_tmp_dir do |state_home|
      write_legacy_request(state_home)
      write_legacy_result(state_home)
      File.write(File.join(state_home, "recovery-migration-v2.json"), "superseded")
      File.write(File.join(state_home, "recovery-migration-v3.json"), "superseded")

      result = migrate(state_home)

      assert_equal 1, result.dig("dispatch_requests", "migrated")
      assert_equal 1, result.dig("dispatch_results", "migrated")
      assert_equal 4, read_json(File.join(state_home, "dispatch_requests", "legacy.json"))["schema_version"]
      assert_equal 2, read_json(File.join(state_home, "dispatch_results", "legacy.json"))["schema_version"]
      refute_path_exists File.join(state_home, "recovery-migration-v2.json")
      refute_path_exists File.join(state_home, "recovery-migration-v3.json")
    end
  end

  def test_queue_migration_tolerates_disappearing_directory_and_malformed_document
    with_tmp_dir do |state_home|
      requests = File.join(state_home, "dispatch_requests")
      FileUtils.mkdir_p(requests)
      malformed = File.join(requests, "malformed.json")
      File.write(malformed, "{")

      result = migrate(state_home)

      assert_equal 0, result.dig("dispatch_requests", "migrated")
      assert_equal "{", File.read(malformed)
    end

    with_tmp_dir do |state_home|
      requests = File.join(state_home, "dispatch_requests")
      FileUtils.mkdir_p(requests)
      original = Dir.method(:children)
      replacement = lambda do |path|
        raise Errno::ENOENT, path if path == requests

        original.call(path)
      end

      result = with_replaced_singleton_method(Dir, :children, replacement) do
        migrate(state_home)
      end
      assert_equal 0, result.dig("dispatch_requests", "migrated")
    end
  end

  def test_storage_health_failure_does_not_replace_migration_error
    with_tmp_dir do |state_home|
      write_v2_record(state_home, lost_attempt(current_attempt(attempt_id: "old")))
      FileUtils.mkdir_p(File.join(state_home, "attempts", "v3", "maintenance"))
      replacement = lambda do |error:, now:|
        raise IOError, "injected storage-health failure"
      end

      with_replaced_instance_method(
        Hive::Attempts::StorageHealth, :fail_migration, replacement
      ) do
        error = assert_raises(Hive::Recovery::Migration::Error) { migrate(state_home) }
        assert_includes error.message, "both attempts/v2 and attempts/v3 contain material state"
        refute_includes error.message, "storage-health"
      end
    end
  end

  private

  def migrate(state_home)
    observer = Object.new
    observer.define_singleton_method(:observe) { |_status, now:| :not_applicable }
    factory = lambda do |store:, state_home:|
      Hive::Attempts::FinalizationMaintenance.new(
        store: store, condition_observer: observer,
        delivery_pending: ->(_record) { false }
      )
    end
    with_replaced_singleton_method(
      Hive::Attempts::FinalizationMaintenance, :runtime, factory
    ) do
      Hive::Recovery::Migration.ensure!(state_home: state_home, now: NOW)
    end
  end

  def fence_payload
    { "schema" => "hive-attempt-layout-fence", "schema_version" => 1, "target" => "v3" }
  end

  def write_fence(state_home, payload = fence_payload)
    path = File.join(state_home, "attempts", "v2")
    write_json(path, payload)
    File.chmod(0o600, path)
    path
  end

  def write_receipt_marker(state_home)
    write_json(File.join(state_home, "recovery-migration-v4.json"), {})
  end

  def write_checkpoint(state_home, phase:, source_count: 0, source_valid_count: 0,
                       source_invalid_count: 0,
                       source_digest: Digest::SHA256.hexdigest(""))
    write_json(File.join(state_home, "attempts", ".v3-cutover.json"), {
      "schema" => "hive-attempt-layout-cutover",
      "schema_version" => 1,
      "phase" => phase,
      "source_count" => source_count,
      "source_valid_count" => source_valid_count,
      "source_invalid_count" => source_invalid_count,
      "source_digest" => source_digest
    })
  end

  def write_v2_record(state_home, data)
    path = File.join(state_home, "attempts", "v2", "records", "#{data.fetch('attempt_id')}.json")
    write_json(path, data)
  end

  def read_json(path)
    JSON.parse(File.binread(path))
  end

  def write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, JSON.generate(data) + "\n")
  end

  def current_attempt(attempt_id:, generation: nil, predecessor_attempt_id: nil, accepted_at: NOW)
    Hive::Attempts::Record.launching(
      attempt_id: attempt_id,
      request_id: "request-#{attempt_id}",
      predecessor_attempt_id: predecessor_attempt_id,
      task_id: "42",
      project: "demo",
      task_slug: "durable-task",
      intended_stage: "4-execute",
      task_generation: generation || "generation-#{attempt_id}",
      progress_token: "progress-#{attempt_id}",
      provider: "codex",
      worker_argv: [ "hive", "run", "durable-task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      starting_revision: nil,
      retry_charge: 0,
      inherited_outputs: [],
      launch_timeout_sec: 30,
      now: accepted_at
    ).to_h
  end

  def lost_attempt(data)
    data.merge(
      "state" => "lost", "claim_deadline" => nil,
      "ended_at" => NOW.iso8601(6),
      "loss" => { "reason" => "owner_gone", "at" => NOW.iso8601(6) }
    )
  end

  def terminal_attempt(data, outcome: "succeeded", exit_status: 0)
    checkpoint = { "progress_token" => data.fetch("progress_token") }
    log_reference = {
      "path" => "logs/#{data.fetch('attempt_id')}.frames", "size" => 4, "sha256" => "1" * 64
    }
    receipt = {
      "attempt_id" => data.fetch("attempt_id"),
      "task_generation" => data.fetch("task_generation"),
      "ownership_generation" => data.fetch("ownership_generation"),
      "task_input_epoch" => data.fetch("task_input_epoch"),
      "outcome" => outcome, "exit_status" => exit_status,
      "started_at" => NOW.iso8601(6), "ended_at" => (NOW + 5).iso8601(6),
      "final_checkpoint" => checkpoint, "output_references" => [],
      "log_reference" => log_reference
    }
    data.merge(
      "state" => "terminal", "outcome" => outcome, "claim_deadline" => nil,
      "started_at" => NOW.iso8601(6), "ended_at" => (NOW + 5).iso8601(6),
      "checkpoint" => checkpoint, "log_reference" => log_reference, "receipt" => receipt
    )
  end

  def write_resolved_outcome(state_home, lost, successor)
    path = File.join(
      state_home, "attempts", "v2", "outputs", lost.fetch("attempt_id"), "lost-outcome.json"
    )
    write_json(path, {
      "status" => "successor_dispatched", "cleanup" => "absent",
      "successor_attempt_id" => successor.fetch("attempt_id")
    })
  end

  def with_replaced_instance_method(klass, name, replacement)
    original = klass.instance_method(name)
    klass.define_method(name, replacement)
    yield
  ensure
    klass.define_method(name, original)
  end

  def inject_after(boundary, state_home, &block)
    case boundary
    when :rename
      original = File.method(:rename)
      source = File.join(state_home, "attempts", "v2")
      target = File.join(state_home, "attempts", "v3")
      with_replaced_singleton_method(File, :rename, lambda { |from, to|
        result = original.call(from, to)
        raise IOError, "injected rename crash" if from == source && to == target
        result
      }, &block)
    when :fence
      original = Hive::AtomicFile.method(:write)
      fence = File.join(state_home, "attempts", "v2")
      with_replaced_singleton_method(Hive::AtomicFile, :write, lambda { |path, *args, **kwargs|
        result = original.call(path, *args, **kwargs)
        raise IOError, "injected fence crash" if path == fence
        result
      }, &block)
    when :index
      original = Hive::Attempts::DecisionIndex.instance_method(:record_terminal)
      fired = false
      with_replaced_instance_method(Hive::Attempts::DecisionIndex, :record_terminal, lambda { |record|
        result = original.bind_call(self, record)
        unless fired
          fired = true
          raise Hive::Attempts::StoreError, "injected index crash"
        end
        result
      }, &block)
    when :proof
      inject_instance_after(Hive::Attempts::PermanentProofStore, :publish, &block)
    when :log
      inject_instance_after(Hive::Attempts::LogArchive, :archive, &block)
    when :hot_removal
      inject_instance_after(Hive::Attempts::Store, :remove_hot_final, &block)
    end
  end

  def inject_instance_after(klass, name)
    original = klass.instance_method(name)
    fired = false
    with_replaced_instance_method(klass, name, lambda { |*args, **kwargs|
      result = original.bind_call(self, *args, **kwargs)
      unless fired
        fired = true
        raise Hive::Attempts::StoreError, "injected #{name} crash"
      end
      result
    }) { yield }
  end

  def write_legacy_request(state_home)
    write_json(File.join(state_home, "dispatch_requests", "legacy.json"), {
      "schema" => "hive-dispatch-request", "schema_version" => 2,
      "request_id" => "legacy-request", "created_at" => NOW.iso8601(6),
      "project" => "demo", "slug" => "durable-task",
      "argv" => [ "hive", "run", "durable-task" ], "requestor" => "healer",
      "chat_id" => nil, "update_id" => nil, "trigger" => "retry"
    })
  end

  def write_legacy_result(state_home)
    write_json(File.join(state_home, "dispatch_results", "legacy.json"), {
      "schema" => "hive-dispatch-result", "schema_version" => 1,
      "request_id" => "legacy-request", "completed_at" => NOW.iso8601(6),
      "status" => "accepted", "reason" => nil
    })
  end
end
