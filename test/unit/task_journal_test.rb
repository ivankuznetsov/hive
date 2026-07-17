require "test_helper"
require "hive/task_journal"
require "hive/attempts/store"
require "hive/babysitter/job_store"

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

  def test_append_once_replays_identical_event_and_rejects_id_collision
    with_writer do |writer, dir|
      attributes = event("reconciliation", event_id: "stable-event")
      first = writer.append_once(attributes)
      replay = writer.append_once(attributes)

      assert_equal first.cursor, replay.cursor
      assert_equal 1, File.readlines(File.join(dir, "events.jsonl")).size

      collision = attributes.merge(reason: "different")
      assert_raises(Hive::TaskJournal::EventIdCollision) do
        writer.append_once(collision)
      end
      assert_equal 1, File.readlines(File.join(dir, "events.jsonl")).size
    end
  end

  def test_append_once_requires_a_deterministic_id
    with_writer do |writer, _dir|
      assert_raises(Hive::TaskJournal::InvalidRecord) do
        writer.append_once(event("reconciliation"))
      end
    end
  end

  def test_babysitter_events_require_a_validator_and_translate_authority_errors
    with_tmp_dir do |dir|
      record = Hive::TaskJournal::Envelope.authoritative(finalization_event)
      records = [ finalized_record ]
      writer = Hive::TaskJournal::Writer.new(task_folder: dir, clock: -> { NOW })
      assert_raises(Hive::TaskJournal::AttemptMismatch) do
        writer.send(:validate!, record, records: records)
      end

      validator = Object.new
      validator.define_singleton_method(:validate_event_authority!) do |_event|
        raise Hive::Babysitter::JobStore::StaleClaim, "stale fence"
      end
      writer = Hive::TaskJournal::Writer.new(
        task_folder: dir, clock: -> { NOW }, authority_validator: validator
      )
      error = assert_raises(Hive::TaskJournal::AttemptMismatch) do
        writer.send(:validate!, record, records: records)
      end
      assert_includes error.message, "stale fence"
    end
  end

  def test_corrupt_existing_json_is_rejected_with_its_line_number
    with_writer do |writer, dir|
      File.write(File.join(dir, "events.jsonl"), "{\n")
      error = assert_raises(Hive::TaskJournal::InvalidRecord) do
        writer.append(event("reconciliation"))
      end
      assert_includes error.message, "line 1"
    end
  end

  def test_finalization_validation_errors_are_normalized_as_invalid_records
    with_tmp_dir do |dir|
      writer = Hive::TaskJournal::Writer.new(task_folder: dir, clock: -> { NOW })
      invalid = finalized_record
      invalid["payload"]["head_generation"] = 2

      error = assert_raises(Hive::TaskJournal::InvalidRecord) do
        writer.send(:validate!, invalid, records: [])
      end
      assert_includes error.message, "head_generation 1"
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

  def finalization_event
    {
      event_id: "job-active", event_type: "babysitter_active", occurred_at: NOW.iso8601(6),
      observed_at: NOW.iso8601(6), task: { "id" => "42", "slug" => "durable-task" },
      workflow: "coding", stage: "8-finalize", attempt_id: "attempt-1", task_generation: 3,
      ownership_generation: "job-1", reason: "active", evidence: [], provenance: { "source" => "test" },
      producer: { "kind" => "babysitter_job", "job_id" => "job-1", "claim_fence" => 1 },
      payload: {
        "job_id" => "job-1", "repository" => "github.com/acme/demo", "pr_number" => 12,
        "pr_url" => "https://github.com/acme/demo/pull/12", "head_sha" => "a" * 40,
        "head_generation" => 1, "finalize_attempt_id" => "attempt-1"
      }
    }
  end

  def finalized_record
    Hive::TaskJournal::Envelope.authoritative(
      finalization_event.merge(
        event_id: "finalized", event_type: "finalized", reason: "handoff",
        producer: { "kind" => "finalize_attempt", "attempt_id" => "attempt-1" }
      )
    )
  end
end
