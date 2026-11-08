require "test_helper"
require "hive/attempts/pending_bookkeeping"

class AttemptsPendingBookkeepingTest < Minitest::Test
  include HiveTestHelper
  NOW = Time.utc(2026, 7, 16, 12)
  OWNER = { "pid" => 123, "start_fingerprint" => "owner", "session_id" => 123, "process_group_id" => 123 }.freeze
  SECRET = "c" * 64

  def test_completion_replays_when_the_store_root_traverses_a_symlink
    with_running(symlink_root: true) do |store, record|
      receipt = receipt_for(store, record)
      store.pending_bookkeeping.prepare_completion(record, receipt: receipt)
      pending = Hive::Attempts::PendingBookkeeping.new(store: store)
      result = pending.read(record)
      assert_equal :valid, result.status
      assert_equal receipt, pending.replay(record, result.document).receipt
    end
  end

  def test_prepared_completion_is_private_and_replays_exact_receipt_after_restart
    with_running do |store, record|
      receipt = receipt_for(store, record)
      pending = Hive::Attempts::PendingBookkeeping.new(store: store)
      path = pending.prepare_completion(record, receipt: receipt)
      assert_equal 0o600, File.stat(path).mode & 0o777
      refute_includes File.read(path), SECRET
      restarted = Hive::Attempts::PendingBookkeeping.new(store: store)
      result = restarted.read(record)
      assert_equal :valid, result.status
      terminal = restarted.replay(record, result.document)
      assert_equal receipt, terminal.receipt
      assert_equal terminal.to_h, restarted.replay(record, result.document).to_h
      assert_path_exists path
    end
  end

  def test_invalid_documents_are_diagnostic_and_never_replace_completion
    with_running do |store, record|
      pending = store.pending_bookkeeping
      path = pending.prepare_completion(record, receipt: receipt_for(store, record))
      original = JSON.parse(File.read(path))
      mutations = [
        ->(doc) { doc.delete("schema") },
        ->(doc) { doc["schema_version"] = 2 },
        ->(doc) { doc["binding"]["lease_version"] += 1 },
        ->(doc) { doc["operation"] = "" },
        ->(doc) { doc["receipt_sha256"] = "0" * 64 },
        ->(doc) { doc["terminal_receipt"] = nil }
      ]
      mutations.each do |mutate|
        document = Marshal.load(Marshal.dump(original))
        mutate.call(document)
        bytes = JSON.generate(document)
        File.write(path, bytes)
        result = pending.read(record)
        assert_equal :invalid, result.status
        refute_empty result.diagnostic
        assert_equal path, pending.record_busy(record, operation: "heartbeat")
        assert_equal bytes, File.read(path)
        assert_equal "running", store.fetch(record.attempt_id).state
      end
    end
  end

  def test_busy_evidence_is_present_until_terminal_publication_is_complete
    with_running do |store, record|
      pending = store.pending_bookkeeping
      refute pending.present?(record)
      pending.record_busy(record, operation: "heartbeat")
      assert pending.present?(record)
      refute pending.retire(record)
      document = pending.read(record).document
      assert_nil pending.replay(record, document)
      path = pending.prepare_completion(record, receipt: receipt_for(store, record))
      terminal = pending.replay(record, pending.read(record).document)
      refute pending.retire(terminal)
      assert_path_exists path
      store.prepare_publication(attempt_id: terminal.attempt_id)
      %w[journal accounting dispatch].each do |consumer|
        store.acknowledge_publication(terminal.attempt_id, consumer: consumer)
      end
      assert pending.retire(terminal)
      refute pending.present?(terminal)
    end
  end

  def test_lost_evidence_is_retained_until_safe_recovery_is_complete
    with_running do |store, record|
      pending = store.pending_bookkeeping
      pending.record_busy(record, operation: "heartbeat")
      lost = store.mark_lost(record, reason: "owner_gone", now: NOW + 3)
      refute pending.retire(lost)
      recovery = Hive::Attempts::LostOutcomeTransition.new(store: store)
      recovery.ensure_for(lost, now: NOW + 3)
      refute pending.retire(lost)
      recovery.update(lost, phase: "ready", cleanup: "no_worker",
                      request_id: recovery.recovery_request_id(lost), now: NOW + 4)
      recovery.update(lost, phase: "complete", now: NOW + 5)
      assert pending.retire(lost)
    end
  end

  def test_storage_failure_is_typed_and_leaves_the_attempt_live
    with_running do |store, record|
      store.payload_store.define_singleton_method(:write_open) { |**| raise Errno::ENOSPC, "full" }
      error = assert_raises(Hive::Attempts::PendingBookkeeping::StorageError) do
        store.pending_bookkeeping.record_busy(record, operation: "heartbeat")
      end
      assert_match(/pending bookkeeping storage failed/, error.message)
      assert_equal "running", store.fetch(record.attempt_id).state
    end
  end

  def test_completion_rejects_redirected_linked_changed_and_corrupt_references
    with_running do |store, record|
      receipt = receipt_for(store, record)
      reference = receipt.fetch("log_reference")
      path = File.join(store.root, reference.fetch("path"))
      bytes = File.binread(path)
      pending = store.pending_bookkeeping
      assert_invalid = lambda do |message|
        error = assert_raises(Hive::Attempts::PendingBookkeeping::InvalidEvidence) do
          pending.prepare_completion(record, receipt: receipt)
        end
        assert_match message, error.message
      end

      link = "#{path}.link"
      File.link(path, link)
      assert_invalid.call(/size or custody/)
      File.unlink(link)
      File.binwrite(path, "x" * bytes.bytesize)
      assert_invalid.call(/digest differs/)
      File.binwrite(path, bytes)

      directory = File.dirname(path)
      moved = "#{directory}.moved"
      File.rename(directory, moved)
      File.symlink(moved, directory)
      assert_invalid.call(/parent is redirected/)
      File.unlink(directory)
      File.rename(moved, directory)

      filesystem = Object.new
      filesystem.define_singleton_method(:realpath) { |value| File.realpath(value) }
      filesystem.define_singleton_method(:lstat) { |value| File.lstat(value) }
      filesystem.define_singleton_method(:open) do |value, flags, &block|
        File.open(value, flags) do |file|
          read = file.method(:read)
          file.define_singleton_method(:read) do |length|
            chunk = read.call(length)
            File.utime(Time.now + 60, Time.now + 60, value) unless chunk
            chunk
          end
          block.call(file)
        end
      end
      pending = Hive::Attempts::PendingBookkeeping.new(store: store, filesystem: filesystem)
      assert_invalid.call(/reference changed/)
      assert_equal "running", store.fetch(record.attempt_id).state
    end
  end

  private

  def with_running(symlink_root: false)
    with_tmp_dir do |root|
      if symlink_root
        target = File.join(root, "state")
        FileUtils.mkdir_p(target)
        link = File.join(root, "linked-state")
        File.symlink(target, link)
        root = File.join(link, "runtime")
      end
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      launching = store.create_launching(
        attempt_id: "pending-attempt", request_id: "pending-request", task_id: "42",
        project: "demo", task_slug: "durable-task", intended_stage: "4-execute",
        task_generation: "generation", progress_token: "progress", provider: "codex",
        worker_argv: [ "/bin/true" ], claim_capability_digest: Hive::Attempts::Capability.digest(SECRET),
        starting_revision: nil, retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: NOW
      )
      claimed = store.claim(launching, owner: OWNER, claim_capability: SECRET, first_heartbeat_timeout_sec: 30, now: NOW)
      running = store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 1)
      store.output_directory(running.attempt_id, create: true)
      writer = store.log_archive.open_writer(running.attempt_id)
      writer.append(:stdout, "completed work\n")
      writer.close
      yield store, running
    end
  end

  def receipt_for(store, record)
    store.prepare_terminal_receipt(
      record, outcome: "succeeded", exit_status: 0, final_checkpoint: record.checkpoint,
      output_references: [], log_reference: Hive::OutputReference.build(store.log_archive.hot_path(record.attempt_id), root: store.root),
      now: NOW + 2
    )
  end
end
