require "test_helper"
require "tmpdir"
require "json_schemer"
require "pathname"
require "hive/patrol_fix/publication_receipt"
require "hive/patrol_fix/receipt_store"

class PatrolFixReceiptStoreTest < Minitest::Test
  def test_append_is_idempotent_for_exact_receipt_and_rejects_conflicts
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: dir)
      receipt = decision_receipt

      assert_equal receipt, store.append!(receipt)
      assert_equal receipt, store.append!(receipt)
      assert_equal [ receipt ], store.read_all
      assert JSONSchemer.schema(
        Pathname.new(Hive::Schemas.schema_path("hive-patrol-fix-receipt"))
      ).valid?(receipt)

      conflicting = Marshal.load(Marshal.dump(receipt))
      conflicting.fetch("payload")["route"] = "blocked"
      assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) do
        store.append!(conflicting)
      end
    end
  end

  def test_rejects_receipts_with_unknown_versions_or_cross_generation_bindings
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: dir)

      assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) do
        store.append!(decision_receipt.merge("schema_version" => 2))
      end

      mismatched = decision_receipt
      mismatched.fetch("task")["generation"] = 2
      assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) do
        store.append!(mismatched)
      end
    end
  end

  def test_rejects_conflicting_terminal_bytes_for_the_same_stage_generation_and_kind
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: dir)
      first = decision_receipt
      store.append!(first)
      conflict = Marshal.load(Marshal.dump(first))
      conflict["receipt_id"] = "decision-2"
      conflict.fetch("payload")["route"] = "blocked"

      assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) do
        store.append!(conflict)
      end
    end
  end

  def test_existing_conflicting_terminal_tuple_fails_closed_on_read
    Dir.mktmpdir do |dir|
      first = decision_receipt
      conflict = Marshal.load(Marshal.dump(first))
      conflict["receipt_id"] = "decision-2"
      conflict.fetch("payload")["route"] = "blocked"
      File.write(
        File.join(dir, Hive::PatrolFix::ReceiptStore::FILENAME),
        Hive::PatrolFix.canonical_json(first) + Hive::PatrolFix.canonical_json(conflict)
      )

      assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) do
        Hive::PatrolFix::ReceiptStore.new(task_folder: dir).read_all
      end
    end
  end

  def test_malformed_oversized_or_symlinked_journal_fails_closed
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: dir)
      File.write(store.path, "not-json\n")
      assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) { store.read_all }

      File.write(store.path, ("x" * Hive::PatrolFix::ReceiptStore::MAX_JOURNAL_BYTES) + "x")
      error = assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) { store.read_all }
      assert_includes error.message, "size limit"

      File.delete(store.path)
      target = File.join(dir, "outside.jsonl")
      File.write(target, "")
      File.symlink(target, store.path)
      error = assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) { store.read_all }
      assert_includes error.message, "symlink"
    end
  end

  def test_decision_schema_is_stage_specific_and_closed
    schemer = JSONSchemer.schema(
      Pathname.new(Hive::Schemas.schema_path("hive-patrol-fix-decision"))
    )
    decision = {
      "schema" => "hive-patrol-fix-decision", "schema_version" => 1,
      "stage" => "inbox", "route" => "fix", "rationale" => "The defect is bounded.",
      "evidence" => [ "The focused reproduction fails." ], "blocker_owner" => "inbox_gate"
    }

    assert schemer.valid?(decision)
    refute schemer.valid?(decision.merge("route" => "publish"))
    refute schemer.valid?(decision.merge("prompt" => "untrusted raw input"))
  end

  def test_validates_publication_reopen_and_timestamp_payloads
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: dir)
      publication = decision_receipt.merge(
        "receipt_id" => "publication-1", "kind" => "publication", "stage" => "publish",
        "payload" => { "not" => "canonical" }
      )
      assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) { store.append!(publication) }

      reopen = decision_receipt.merge(
        "receipt_id" => "reopen-1", "kind" => "reopen", "stage" => "inbox",
        "payload" => {
          "outcome_receipt_id" => "decision-1", "operator" => "cli:test",
          "carried_receipts" => [ "fix-1", "validation-1" ]
        }
      )
      assert_equal reopen, store.append!(reopen)

      invalid_time = decision_receipt.merge("receipt_id" => "decision-time", "recorded_at" => "bad")
      assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) { store.append!(invalid_time) }
    end
  end

  def test_translates_journal_write_read_and_serialization_failures
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: dir)
      [ Errno::ELOOP.new("loop"), IOError.new("closed") ].each do |failure|
        original = File.method(:open)
        File.define_singleton_method(:open, ->(*) { raise failure })
        begin
          assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) do
            store.append!(decision_receipt)
          end
        ensure
          File.define_singleton_method(:open, original)
        end
      end

      File.write(store.path, Hive::PatrolFix.canonical_json(decision_receipt))
      [ Errno::ELOOP.new("loop"), IOError.new("closed") ].each do |failure|
        original = File.method(:open)
        File.define_singleton_method(:open, ->(*) { raise failure })
        begin
          assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) { store.read_all }
        ensure
          File.define_singleton_method(:open, original)
        end
      end

      File.delete(store.path)
      original = Hive::PatrolFix.method(:canonical_json)
      Hive::PatrolFix.define_singleton_method(:canonical_json, ->(*) { raise JSON::GeneratorError, "bad value" })
      begin
        assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) do
          store.append!(decision_receipt)
        end
      ensure
        Hive::PatrolFix.define_singleton_method(:canonical_json, original)
      end
    end
  end

  private

  def decision_receipt
    {
      "schema" => "hive-patrol-fix-receipt",
      "schema_version" => 1,
      "receipt_id" => "decision-1",
      "kind" => "decision",
      "stage" => "inbox",
      "task" => { "slug" => "repair-login-260820-abcd", "generation" => 1 },
      "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 },
      "recorded_at" => "2026-08-20T12:00:00Z",
      "payload" => {
        "route" => "reject",
        "rationale" => "The current code no longer contains the reported branch.",
        "evidence" => [ "The replacement path is covered by the focused test." ],
        "blocker_owner" => "inbox_gate",
        "head_revision" => "b" * 40
      }
    }
  end
end
