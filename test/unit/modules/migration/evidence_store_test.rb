require "test_helper"
require "hive/modules/migration/evidence_store"

class ModulesMigrationEvidenceStoreTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 28, 12)

  def test_store_is_append_only_idempotent_and_restart_safe
    with_tmp_dir do |root|
      store = Hive::Modules::Migration::EvidenceStore.new(root: root)
      capture = capture_for(recorded_at: NOW)
      intent = intent_for
      receipt = Hive::Modules::Migration::EffectReceipt.build(
        intent: intent,
        status: "committed",
        outcome: { "state" => "open", "remote_id" => "owner/demo#7" },
        recorded_at: NOW + 1
      )

      assert_equal :created, store.append_capture(capture).status
      assert_equal :duplicate, store.append_capture(capture).status
      assert_equal :created, store.append_receipt(receipt).status
      assert_equal :duplicate, store.append_receipt(receipt).status

      restarted = Hive::Modules::Migration::EvidenceStore.new(root: root)
      assert_equal capture, restarted.fetch_capture(capture.capture_id)
      assert_equal receipt, restarted.fetch_receipt(receipt.receipt_id)
      assert_equal [ capture ], restarted.captures
      assert_equal [ receipt ], restarted.receipts
    end
  end

  def test_same_identity_with_different_bytes_is_corruption
    with_tmp_dir do |root|
      store = Hive::Modules::Migration::EvidenceStore.new(root: root)
      capture = capture_for(recorded_at: NOW)
      store.append_capture(capture)

      conflicting = Hive::Modules::Migration::PatrolCapture.from_h(
        capture.to_h.merge("recorded_at" => (NOW + 60).iso8601(6))
      )
      error = assert_raises(Hive::ConfigError) do
        store.append_capture(conflicting)
      end
      assert_equal "patrol evidence identity conflicts with existing bytes", error.message
    end
  end

  def test_malformed_evidence_fails_closed_after_restart
    with_tmp_dir do |root|
      store = Hive::Modules::Migration::EvidenceStore.new(root: root)
      capture = capture_for(recorded_at: NOW)
      store.append_capture(capture)
      path = File.join(root, "captures", "#{capture.capture_id}.json")
      File.write(path, "{bad")

      restarted = Hive::Modules::Migration::EvidenceStore.new(root: root)
      error = assert_raises(Hive::ConfigError) { restarted.captures }
      assert_equal "patrol evidence is malformed", error.message
    end
  end

  def test_fetch_rejects_untrusted_paths_and_no_follow_reads
    with_tmp_dir do |root|
      store = Hive::Modules::Migration::EvidenceStore.new(root: root)
      assert_raises(Hive::ConfigError) { store.fetch_capture("../../config") }
      assert_raises(Hive::ConfigError) { store.fetch_receipt("/tmp/receipt") }

      capture = capture_for(recorded_at: NOW)
      outside = File.join(root, "outside.json")
      File.write(outside, Hive::Modules::Migration::PatrolEvidence.canonical(capture.to_h))
      path = File.join(root, "captures", "#{capture.capture_id}.json")
      File.symlink(outside, path)

      error = assert_raises(Hive::ConfigError) do
        store.fetch_capture(capture.capture_id)
      end
      assert_equal "patrol evidence is malformed", error.message
    end
  end

  def test_occurrence_and_intent_indexes_avoid_history_scans
    with_tmp_dir do |root|
      store = Hive::Modules::Migration::EvidenceStore.new(root: root)
      first = receipt_for(
        occurrence_id: "occ-#{'a' * 64}",
        target: "github.com/owner/demo:one"
      )
      second = receipt_for(
        occurrence_id: "occ-#{'b' * 64}",
        target: "github.com/owner/demo:two"
      )
      store.append_receipt(first)
      store.append_receipt(second)

      page = store.receipts_for_occurrence(first.intent.occurrence_id)
      assert_equal [ first ], page.records
      assert_nil page.next_cursor
      assert_equal [ first ], store.receipts_for_intent(first.intent.intent_id).records
      assert File.file?(
        File.join(
          root, "indexes", "occurrences",
          "#{first.intent.occurrence_id}.json"
        )
      )
      assert File.file?(
        File.join(root, "indexes", "intents", "#{first.intent.intent_id}.json")
      )
    end
  end

  def test_receipt_index_repair_is_restart_safe_and_globally_paged
    with_tmp_dir do |root|
      store = Hive::Modules::Migration::EvidenceStore.new(root: root)
      receipts = %w[a b c].map do |suffix|
        receipt_for(
          occurrence_id: "occ-#{suffix * 64}",
          target: "github.com/owner/demo:#{suffix}"
        )
      end
      receipts.each { |receipt| store.append_receipt(receipt) }
      FileUtils.rm_r(File.join(root, "indexes"))

      cursor = nil
      processed = 0
      4.times do
        restarted = Hive::Modules::Migration::EvidenceStore.new(root: root)
        reads = 0
        original = restarted.method(:read_record)
        restarted.define_singleton_method(:read_record) do |*args, **options|
          reads += 1
          original.call(*args, **options)
        end
        page = restarted.repair_receipt_indexes(limit: 1, cursor: cursor)
        assert_operator reads, :<=, 1
        processed += page.processed
        cursor = page.next_cursor
        break if page.complete

        assert_match(/\Arepair-v2\./, cursor)
      end

      assert_nil cursor
      assert_equal receipts.size, processed
      receipts.each do |receipt|
        page = Hive::Modules::Migration::EvidenceStore.new(root: root)
          .receipts_for_occurrence(receipt.intent.occurrence_id)
        assert_equal [ receipt ], page.records
        assert_nil page.next_cursor
      end
    end
  end

  def test_receipt_index_repair_cursor_is_bound_to_its_store
    with_tmp_dir do |root|
      first_root = File.join(root, "first")
      first = Hive::Modules::Migration::EvidenceStore.new(root: first_root)
      %w[a b].each do |suffix|
        first.append_receipt(
          receipt_for(
            occurrence_id: "occ-#{suffix * 64}",
            target: "github.com/owner/demo:#{suffix}"
          )
        )
      end
      cursor = first.repair_receipt_indexes(limit: 1).next_cursor
      refute_nil cursor

      second = Hive::Modules::Migration::EvidenceStore.new(
        root: File.join(root, "second")
      )
      error = assert_raises(Hive::ConfigError) do
        second.repair_receipt_indexes(limit: 1, cursor: cursor)
      end
      assert_equal "patrol evidence repair cursor is malformed", error.message
    end
  end

  def test_store_and_append_filesystem_failures_are_domain_errors
    with_tmp_dir do |root|
      blocked_root = File.join(root, "blocked")
      File.write(blocked_root, "not a directory")
      error = assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::EvidenceStore.new(root: blocked_root)
      end
      assert_match(/patrol evidence store is unavailable/, error.message)

      store = Hive::Modules::Migration::EvidenceStore.new(
        root: File.join(root, "append")
      )
      captures_root = File.join(store.root, "captures")
      FileUtils.rm_r(captures_root)
      File.write(captures_root, "not a directory")
      error = assert_raises(Hive::ConfigError) do
        store.append_capture(capture_for(recorded_at: NOW))
      end
      assert_equal "patrol evidence is malformed", error.message

      unserializable = Object.new
      unserializable.define_singleton_method(:to_h) do
        raise Errno::EIO, "serialization failed"
      end
      error = assert_raises(Hive::ConfigError) do
        store.send(
          :append,
          File.join(root, "unused"),
          "cap-#{'a' * 64}",
          unserializable
        )
      end
      assert_match(/patrol evidence could not be appended/, error.message)

      locked = Hive::Modules::Migration::EvidenceStore.new(
        root: File.join(root, "lock")
      )
      FileUtils.rm_r(locked.root)
      File.write(locked.root, "not a directory")
      error = assert_raises(Hive::ConfigError) do
        locked.append_capture(capture_for(recorded_at: NOW))
      end
      assert_match(/store lock is unavailable/, error.message)
    end
  end

  def test_history_path_and_record_corruption_fail_closed
    with_tmp_dir do |root|
      store = Hive::Modules::Migration::EvidenceStore.new(root: root)
      capture = capture_for(recorded_at: NOW)
      foreign_id = "cap-#{'f' * 64}"

      error = assert_raises(Hive::ConfigError) do
        store.send(
          :read_record,
          File.join(root, "receipts", "#{capture.capture_id}.json"),
          expected_id: capture.capture_id,
          type: Hive::Modules::Migration::PatrolCapture
        )
      end
      assert_equal "patrol evidence is malformed", error.message

      missing = store.send(
        :read_record,
        File.join(root, "captures", "#{foreign_id}.json"),
        expected_id: foreign_id,
        type: Hive::Modules::Migration::PatrolCapture
      )
      assert_nil missing

      forged = capture.to_h.merge("capture_id" => foreign_id)
      File.write(
        File.join(root, "captures", "#{foreign_id}.json"),
        Hive::Modules::Migration::PatrolEvidence.canonical(forged)
      )
      error = assert_raises(Hive::ConfigError) do
        store.fetch_capture(foreign_id)
      end
      assert_equal "patrol evidence is malformed", error.message

      File.write(File.join(root, "captures", "unexpected.json"), "{}")
      error = assert_raises(Hive::ConfigError) do
        store.send(
          :records,
          File.join(root, "captures"),
          type: Hive::Modules::Migration::PatrolCapture
        )
      end
      assert_equal "patrol evidence is malformed", error.message
    end
  end

  def test_index_limits_and_malformed_index_inputs_fail_closed
    with_tmp_dir do |root|
      store = Hive::Modules::Migration::EvidenceStore.new(root: root)
      receipt = receipt_for(
        occurrence_id: "occ-#{'a' * 64}",
        target: "github.com/owner/demo:new"
      )
      occurrence_id = receipt.intent.occurrence_id
      index_path = File.join(
        root, "indexes", "occurrences", "#{occurrence_id}.json"
      )
      receipt_ids = 128.times.map do |index|
        "receipt-#{index.to_s(16).rjust(64, '0')}"
      end
      index = {
        "schema" => Hive::Modules::Migration::EvidenceStore::INDEX_SCHEMA,
        "schema_version" => 1,
        "kind" => "occurrence",
        "identity" => occurrence_id,
        "receipt_ids" => receipt_ids
      }
      File.write(
        index_path,
        Hive::Modules::Migration::PatrolEvidence.canonical(index)
      )
      error = assert_raises(Hive::ConfigError) do
        store.send(:update_receipt_indexes_unlocked, receipt)
      end
      assert_match(/occurrence exceeds the effect limit/, error.message)

      File.write(index_path, "{bad")
      error = assert_raises(Hive::ConfigError) do
        store.receipts_for_occurrence(occurrence_id)
      end
      assert_equal "patrol evidence index is malformed", error.message

      assert_raises(Hive::ConfigError) do
        store.send(:index_path, :unknown, occurrence_id)
      end
      page = store.receipts_for_occurrence(
        "occ-#{'b' * 64}",
        cursor: "receipt-#{'c' * 64}"
      )
      assert_empty page.records
      assert_raises(Hive::ConfigError) do
        store.receipts_for_occurrence(occurrence_id, limit: 0)
      end
      assert_raises(Hive::ConfigError) do
        store.receipts_for_occurrence(occurrence_id, limit: "many")
      end
    end
  end

  def test_repair_rejects_non_directories_names_and_invalid_cursors
    with_tmp_dir do |root|
      store = Hive::Modules::Migration::EvidenceStore.new(root: root)
      receipts_root = File.join(root, "receipts")
      FileUtils.rm_r(receipts_root)
      File.symlink(File.join(root, "captures"), receipts_root)
      assert_raises(Hive::ConfigError) do
        store.repair_receipt_indexes
      end
      File.unlink(receipts_root)
      assert_raises(Hive::ConfigError) do
        store.repair_receipt_indexes
      end
      FileUtils.mkdir_p(receipts_root)
      File.write(File.join(receipts_root, "unexpected"), "{}")
      assert_raises(Hive::ConfigError) do
        store.repair_receipt_indexes
      end
      File.unlink(File.join(receipts_root, "unexpected"))

      assert_raises(Hive::ConfigError) do
        store.repair_receipt_indexes(cursor: "repair-v2.bad")
      end

      hostile_cursor = Object.new
      hostile_cursor.define_singleton_method(:to_s) do
        raise ArgumentError, "not text"
      end
      assert_raises(Hive::ConfigError) do
        store.repair_receipt_indexes(cursor: hostile_cursor)
      end
    end
  end

  def test_bounded_reads_detect_directory_and_inode_races
    with_tmp_dir do |root|
      store = Hive::Modules::Migration::EvidenceStore.new(root: root)
      assert_raises(Hive::ConfigError) do
        store.send(
          :bounded_paths,
          File.join(root, "missing")
        )
      end

      assert_raises(Hive::ConfigError) do
        store.send(
          :bounded_regular_read,
          "/proc/self/stat",
          max_bytes: 0
        )
      end

      path = File.join(root, "race.json")
      File.write(path, "{}")
      fake_stat = File.stat(__FILE__)
      fake_io = Object.new
      fake_io.define_singleton_method(:stat) { fake_stat }
      with_file_open_override(path, fake_io) do
        assert_raises(Hive::ConfigError) do
          store.send(:bounded_regular_read, path, max_bytes: 16)
        end
      end
    end
  end

  private

  def with_file_open_override(target, fake_io)
    original = File.method(:open)
    File.singleton_class.define_method(:open) do |path, *args, &block|
      if path == target
        block ? block.call(fake_io) : fake_io
      else
        original.call(path, *args, &block)
      end
    end
    yield
  ensure
    File.singleton_class.define_method(:open, original)
  end

  def capture_for(recorded_at:)
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: { "kind" => "schedule", "id" => "timer-1" },
      reservation: { "kind" => "ordinary", "id" => "reservation-1" },
      owner: "legacy",
      owner_epoch: 2,
      selection_input: {
        "kind" => "operation",
        "operation" => "evidence-store-test"
      },
      selection:
        Hive::Modules::Migration::PatrolDecisionProjection.build(
          module_name: "patrol",
          rationale: "due"
        ),
      outcome_class: "complete",
      outcome: { "rationale" => "complete" },
      occurred_at: NOW,
      recorded_at: recorded_at
    )
  end

  def intent_for
    Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol",
      occurrence_id: "occ-#{'a' * 64}",
      authority: "legacy",
      owner_epoch: 2,
      sink: "pull_request",
      target: "github.com/owner/demo:head-ref",
      idempotency_key: "finding-1:pull-request",
      capability: "github_pull_requests",
      created_at: NOW
    )
  end

  def receipt_for(occurrence_id:, target:)
    intent = Hive::Modules::Migration::EffectIntent.build(
      module_name: "patrol",
      occurrence_id: occurrence_id,
      authority: "legacy",
      owner_epoch: 2,
      sink: "pull_request",
      target: target,
      idempotency_key: target,
      capability: "github_pull_requests",
      created_at: NOW
    )
    Hive::Modules::Migration::EffectReceipt.build(
      intent: intent,
      status: "committed",
      outcome: { "target" => target },
      recorded_at: NOW + 1
    )
  end
end
