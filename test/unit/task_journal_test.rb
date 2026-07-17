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

      bytes = File.binread(File.join(dir, "events.jsonl"))
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

  def test_malformed_authoritative_records_fail_before_writing
    with_writer do |writer, dir|
      invalid = event("condition_observed", task_generation: "3")
      assert_raises(Hive::TaskJournal::InvalidRecord) { writer.append(invalid) }
      refute File.exist?(File.join(dir, "events.jsonl"))

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
    with_writer do |writer, _dir|
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
    ensure
      File.define_singleton_method(:open, original_open) if original_open
    end
  end

  def test_legacy_lines_and_authoritative_lines_share_one_jsonl_journal
    with_writer do |writer, dir|
      Hive::Events.emit(task_folder: dir, slug: "durable-task", stage: "4-execute",
                        event_type: :stage_enter, message: "start")
      writer.append(event("condition_observed"))

      records = File.readlines(File.join(dir, "events.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[stage_enter condition_observed], records.map { |record| record.fetch("event_type") }
      refute records.first.key?("schema")
      assert_equal Hive::TaskJournal::Envelope::SCHEMA, records.last.fetch("schema")
    end
  end

  private

  def with_writer
    with_tmp_dir do |dir|
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      store.create_launching(
        attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
        task_id: "42", project: "demo", task_slug: "durable-task", intended_stage: "4-execute",
        task_generation: "ownership-1", ownership_generation: "ownership-1", task_input_epoch: 3,
        progress_token: "progress", provider: "codex", starting_revision: nil,
        retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: NOW
      )
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
