require "test_helper"
require "hive/task_journal"
require "hive/attempts/store"

class TaskJournalTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 17, 10, 0, 0)

  def test_strict_batch_append_is_durable_and_returns_cursor_hash_and_event_id
    with_writer do |writer, dir|
      result = writer.append_batch([
        event("condition_observed", reason: "attempt_running"),
        event("condition_observed", reason: "changes_present", commit_generation: 1)
      ])

      bytes = File.binread(File.join(dir, "task-journal.jsonl"))
      lines = bytes.lines.map { |line| JSON.parse(line) }
      assert_equal 2, lines.size
      assert_equal bytes.bytesize, result.cursor
      assert_equal lines.last.fetch("event_id"), result.event_id
      assert_equal Digest::SHA256.hexdigest(bytes), result.journal_hash
      assert_equal %w[event-1 event-2], result.records.map { |record| record.fetch("event_id") }
      assert lines.all? { |record| record["task_generation"] == 3 }
    end
  end

  def test_legacy_baseline_is_the_only_legacy_identity
    with_tmp_dir do |dir|
      writer = Hive::TaskJournal::Writer.new(task_folder: dir, clock: -> { NOW })
      result = writer.append(
        event("legacy_baseline", attempt_id: "legacy", task_generation: 0,
             ownership_generation: nil, reason: "marker_import")
      )
      assert_equal "legacy", result.records.first.fetch("attempt_id")

      error = assert_raises(Hive::TaskJournal::AttemptMismatch) do
        writer.append(event("condition_observed", attempt_id: "legacy", task_generation: 0))
      end
      assert_includes error.message, "baseline"
    end
  end

  def test_unknown_cross_task_stage_and_generation_attempts_are_rejected
    with_writer do |writer, _dir|
      variants = [
        event("condition_observed", attempt_id: "missing"),
        event("condition_observed", task: { "id" => "42", "slug" => "other" }),
        event("condition_observed", stage: "6-review"),
        event("condition_observed", task_generation: 4),
        event("condition_observed", ownership_generation: "wrong")
      ]
      variants.each do |candidate|
        assert_raises(Hive::TaskJournal::AttemptMismatch) { writer.append(candidate) }
      end
    end
  end

  def test_missing_and_cyclic_attempt_lineage_fail_closed
    with_writer do |writer, _dir|
      store = writer.attempt_store
      first_path = store.record_path("attempt-1")
      first = JSON.parse(File.binread(first_path))
      File.write(first_path, JSON.generate(first.merge("predecessor_attempt_id" => "missing")) + "\n")

      error = assert_raises(Hive::TaskJournal::AttemptMismatch) do
        writer.append(event("condition_observed"))
      end
      assert_includes error.message, "missing predecessor"

      second = first.merge(
        "attempt_id" => "attempt-2", "request_id" => "request-2",
        "predecessor_attempt_id" => "attempt-1"
      )
      File.write(store.record_path("attempt-2"), JSON.generate(second) + "\n")
      File.write(
        first_path,
        JSON.generate(first.merge("predecessor_attempt_id" => "attempt-2")) + "\n"
      )
      fresh_writer = Hive::TaskJournal::Writer.new(
        task_folder: writer.task_folder, attempt_store: store, clock: -> { NOW }
      )
      error = assert_raises(Hive::TaskJournal::AttemptMismatch) do
        fresh_writer.append(event("condition_observed", attempt_id: "attempt-2"))
      end
      assert_includes error.message, "lineage cycle"
    end
  end

  def test_attempt_lineage_rejects_an_incompatible_predecessor_identity
    with_writer do |writer, _dir|
      store = writer.attempt_store
      first_path = store.record_path("attempt-1")
      first = JSON.parse(File.binread(first_path))
      second = first.merge(
        "attempt_id" => "attempt-2", "request_id" => "request-2",
        "predecessor_attempt_id" => "attempt-1"
      )
      File.write(store.record_path("attempt-2"), JSON.generate(second) + "\n")
      File.write(first_path, JSON.generate(first.merge("task_slug" => "other-task")) + "\n")

      fresh_writer = Hive::TaskJournal::Writer.new(
        task_folder: writer.task_folder, attempt_store: store, clock: -> { NOW }
      )
      error = assert_raises(Hive::TaskJournal::AttemptMismatch) do
        fresh_writer.append(event("condition_observed", attempt_id: "attempt-2"))
      end
      assert_includes error.message, "incompatible identity"
    end
  end

  def test_malformed_authoritative_records_fail_before_writing
    with_writer do |writer, dir|
      invalid = event("condition_observed", task_generation: "3")
      assert_raises(Hive::TaskJournal::InvalidRecord) { writer.append(invalid) }
      refute File.exist?(File.join(dir, "task-journal.jsonl"))

      assert_raises(Hive::TaskJournal::InvalidRecord) { writer.append_batch([]) }

      malformed_condition = event("condition_observed", payload: {
                                    "condition" => "ChangesPresent", "state" => "superseded"
                                  })
      assert_raises(Hive::TaskJournal::InvalidRecord) { writer.append(malformed_condition) }
    end
  end

  def test_each_authoritative_envelope_invariant_fails_closed
    with_writer do |writer, _dir|
      invalid_events = [
        event("unknown_event"),
        event("reconciliation", task: nil),
        event("reconciliation", commit_generation: -1),
        event("reconciliation", evidence: {}),
        event("reconciliation", occurred_at: "not-a-time")
      ]
      invalid_events.each do |candidate|
        assert_raises(Hive::TaskJournal::InvalidRecord) { writer.append(candidate) }
      end

      envelope = Hive::TaskJournal::Envelope.authoritative(event("reconciliation"))
      envelope["schema"] = "unsupported"
      assert_raises(Hive::TaskJournal::InvalidRecord) do
        writer.send(:validate!, envelope)
      end
    end
  end

  def test_strict_io_failure_surfaces_instead_of_becoming_acknowledgement
    with_writer do |writer, dir|
      original_open = File.method(:open)
      File.define_singleton_method(:open) do |path, *args, **kwargs, &block|
        if path.to_s.end_with?(Hive::TaskJournal::JOURNAL_BASENAME) && block
          original_open.call(path, *args, **kwargs) do |file|
            file.define_singleton_method(:fsync) { raise Errno::ENOSPC }
            block.call(file)
          end
        else
          original_open.call(path, *args, **kwargs, &block)
        end
      end
      error = assert_raises(Hive::TaskJournal::Error) { writer.append(event("condition_observed")) }
      assert_includes error.message, "ENOSPC"
      assert_equal "", File.binread(File.join(dir, "task-journal.jsonl"))
    ensure
      File.define_singleton_method(:open, original_open) if original_open
    end
  end

  def test_short_syswrites_are_retried_until_the_complete_batch_is_durable
    with_writer do |writer, dir|
      original_open = File.method(:open)
      replacement = lambda do |path, *args, **kwargs, &block|
        unless path.to_s.end_with?(Hive::TaskJournal::JOURNAL_BASENAME) && block
          next original_open.call(path, *args, **kwargs, &block)
        end

        original_open.call(path, *args, **kwargs) do |file|
          syswrite = file.method(:syswrite)
          file.define_singleton_method(:syswrite) { |bytes| syswrite.call(bytes.byteslice(0, 11)) }
          block.call(file)
        end
      end

      with_replaced_singleton_method(File, :open, replacement) do
        writer.append(event("condition_observed"))
      end

      record = JSON.parse(File.binread(File.join(dir, "task-journal.jsonl")))
      assert_equal "event-1", record.fetch("event_id")
    end
  end

  def test_partial_append_failure_rolls_back_to_the_previous_durable_boundary
    with_writer do |writer, dir|
      writer.append(event("condition_observed"))
      path = File.join(dir, "task-journal.jsonl")
      before = File.binread(path)
      original_open = File.method(:open)
      replacement = lambda do |opened_path, *args, **kwargs, &block|
        unless opened_path.to_s.end_with?(Hive::TaskJournal::JOURNAL_BASENAME) && block
          next original_open.call(opened_path, *args, **kwargs, &block)
        end

        original_open.call(opened_path, *args, **kwargs) do |file|
          syswrite = file.method(:syswrite)
          calls = 0
          file.define_singleton_method(:syswrite) do |bytes|
            calls += 1
            raise Errno::ENOSPC if calls > 1

            syswrite.call(bytes.byteslice(0, 13))
          end
          block.call(file)
        end
      end

      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::TaskJournal::Error) { writer.append(event("condition_observed")) }
      end
      assert_equal before, File.binread(path)
    end
  end

  def test_retry_after_failed_first_append_fsyncs_the_existing_empty_journal_entry
    with_writer do |writer, dir|
      original_open = File.method(:open)
      replacement = lambda do |path, *args, **kwargs, &block|
        unless path.to_s.end_with?(Hive::TaskJournal::JOURNAL_BASENAME) && block
          next original_open.call(path, *args, **kwargs, &block)
        end

        original_open.call(path, *args, **kwargs) do |file|
          file.define_singleton_method(:syswrite) { |_bytes| raise Errno::ENOSPC }
          block.call(file)
        end
      end
      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::TaskJournal::Error) { writer.append(event("condition_observed")) }
      end
      assert_equal "", File.binread(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME))

      fsynced = []
      with_replaced_singleton_method(
        Hive::AtomicFile, :fsync_directory, ->(path) { fsynced << path }
      ) do
        writer.append(event("condition_observed"))
      end
      assert_equal [ dir ], fsynced
    end
  end

  def test_legacy_telemetry_and_authoritative_records_use_separate_jsonl_contracts
    with_writer do |writer, dir|
      Hive::Events.emit(task_folder: dir, slug: "durable-task", stage: "4-execute",
                        event_type: :stage_enter, message: "start")
      writer.append(event("condition_observed"))

      telemetry = File.readlines(File.join(dir, "events.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      records = File.readlines(File.join(dir, "task-journal.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal [ "stage_enter" ], telemetry.map { |record| record.fetch("event_type") }
      assert_equal [ "condition_observed" ], records.map { |record| record.fetch("event_type") }
      refute telemetry.first.key?("schema")
      assert_equal Hive::TaskJournal::Envelope::SCHEMA, records.first.fetch("schema")
    end
  end

  def test_idempotent_append_reuses_equivalent_identity_and_rejects_conflict
    with_writer do |writer, dir|
      identity = event(
        "implementation_identity_captured",
        reason: "execute_identity_captured",
        payload: {
          "idempotency_key" => "task/3/execute-identity",
          "identity" => { "provider" => "codex", "model" => "gpt-5.6-sol" }
        }
      )
      first = writer.append_idempotent(identity, idempotency_key: "task/3/execute-identity")
      second = writer.append_idempotent(identity, idempotency_key: "task/3/execute-identity")

      assert_equal first.event_id, second.event_id
      assert_equal 1, File.readlines(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME)).size

      conflict = Marshal.load(Marshal.dump(identity))
      conflict[:payload]["identity"]["provider"] = "claude"
      assert_raises(Hive::TaskJournal::Conflict) do
        writer.append_idempotent(conflict, idempotency_key: "task/3/execute-identity")
      end
    end
  end

  private

  def with_writer
    with_tmp_dir do |dir|
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      launching = store.create_launching(
        attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
        task_id: "42", project: "demo", task_slug: "durable-task", intended_stage: "4-execute",
        task_generation: "ownership-1", ownership_generation: "ownership-1", task_input_epoch: 3,
        progress_token: "progress", provider: "codex", starting_revision: nil,
        worker_argv: [ "hive", "run", "durable-task" ],
        claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
        retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: NOW
      )
      claimed = store.claim(
        launching, owner: { "pid" => Process.pid }, claim_capability: "c" * 64,
        first_heartbeat_timeout_sec: 30, now: NOW
      )
      store.first_heartbeat(claimed, stale_sec: 30, now: NOW)
      sequence = 0
      writer = Hive::TaskJournal::Writer.new(
        task_folder: dir, attempt_store: store, clock: -> { NOW },
        id_generator: -> { sequence += 1; "event-#{sequence}" }
      )
      yield writer, dir
    end
  end

  def event(type, overrides = {})
    {
      event_type: type,
      task: { "id" => "42", "slug" => "durable-task" },
      workflow: "coding",
      stage: "4-execute",
      attempt_id: "attempt-1",
      task_generation: 3,
      ownership_generation: "ownership-1",
      commit_generation: 0,
      reason: "observed",
      evidence: [ { "type" => "commit", "sha" => "a" * 40, "branch" => "feature" } ],
      provenance: { "source" => "test" },
      payload: { "condition" => "ChangesPresent", "state" => "satisfied" }
    }.merge(overrides)
  end
end
