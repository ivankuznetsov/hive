require "test_helper"
require "hive/task_activity"
require "hive/attempts/store"

class TaskActivityTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 12, 12, 0, 0)

  def test_records_one_typed_authoritative_activity
    with_activity do |activity, dir|
      result = activity.record(
        kind: "attempt_admitted", operation_id: "attempt/attempt-1/admitted",
        reason: "durable attempt admitted", source: "attempt_dispatcher",
        correlation_id: "request-1", payload: { "provider" => "codex" }
      )

      record = JSON.parse(File.read(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME)))
      assert_equal result.event_id, record.fetch("event_id")
      assert_equal "activity_recorded", record.fetch("event_type")
      assert_equal "attempt_admitted", record.dig("payload", "activity_kind")
      assert_equal "request-1", record.dig("payload", "correlation_id")
      assert_equal "attempt_dispatcher", record.dig("provenance", "source")
      assert_equal "2026-08-12T12:00:00.000000Z", record.fetch("observed_at")
    end
  end

  def test_duplicate_operation_is_idempotent_and_conflicting_duplicate_is_rejected
    with_activity do |activity, dir|
      attributes = {
        kind: "attempt_admitted", operation_id: "attempt/attempt-1/admitted",
        reason: "admitted", source: "attempt_dispatcher"
      }
      first = activity.record(**attributes)
      second = activity.record(**attributes)

      assert_equal first.event_id, second.event_id
      assert_equal 1, File.readlines(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME)).size
      assert_raises(Hive::TaskActivity::Conflict) do
        activity.record(**attributes.merge(reason: "different"))
      end
    end
  end

  def test_attempt_binding_mismatch_is_an_explicit_append_failure
    with_activity(task_generation: 4) do |activity, dir|
      error = assert_raises(Hive::TaskActivity::AppendFailed) do
        activity.record(
          kind: "session_started", operation_id: "session/session-1/start",
          reason: "started", source: "agent_runtime"
        )
      end
      assert_includes error.message, "durable attempt mismatch"
      refute File.exist?(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME))
    end
  end

  def test_redacts_secrets_and_rejects_forbidden_or_absolute_evidence
    with_activity do |activity, dir|
      token = "ghp_#{'a' * 36}"
      activity.record(
        kind: "context_launch_captured", operation_id: "context/attempt-1/launch",
        reason: "captured", source: "context_provenance",
        evidence: [ { "type" => "repository", "detail" => token,
                      "evidence_ref" => "context-receipts/attempt-1.json" } ]
      )
      body = File.read(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME))
      refute_includes body, token
      assert_includes body, "REDACTED:github_token"

      assert_raises(Hive::TaskActivity::InvalidActivity) do
        activity.record(
          kind: "context_selection_reported", operation_id: "context/attempt-1/selection",
          reason: "selected", source: "context_provenance",
          payload: { "prompt" => "do something" }
        )
      end
      assert_raises(Hive::TaskActivity::InvalidActivity) do
        activity.record(
          kind: "context_selection_reported", operation_id: "context/attempt-1/selection-2",
          reason: "selected", source: "context_provenance",
          evidence: [ { "evidence_ref" => "/home/operator/wiki/index.md" } ]
        )
      end
    end
  end

  def test_correction_keeps_the_superseded_event_reference
    with_activity do |activity, _dir|
      result = activity.record(
        kind: "correction", operation_id: "correction/event-1",
        reason: "external clock corrected", source: "operator",
        supersedes_event_id: "event-1"
      )

      assert_equal "event-1", result.records.first.dig("payload", "supersedes_event_id")
    end
  end

  def test_writer_failure_never_becomes_an_acknowledgement
    writer = Object.new
    writer.define_singleton_method(:append_idempotent) do |*|
      raise Hive::TaskJournal::Error, "disk unavailable"
    end
    activity = build_activity(writer: writer)

    error = assert_raises(Hive::TaskActivity::AppendFailed) do
      activity.record(
        kind: "activity_gap", operation_id: "gap/op-1",
        reason: "append failed", source: "operator"
      )
    end
    assert_includes error.message, "disk unavailable"
  end

  private

  def with_activity(task_generation: 3)
    with_tmp_dir do |dir|
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      launching = store.create_launching(
        attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
        task_id: "42", project: "demo", task_slug: "durable-task",
        intended_stage: "4-execute", task_generation: "ownership-1",
        ownership_generation: "ownership-1", task_input_epoch: 3,
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
      yield build_activity(
        writer: writer, task_folder: dir, task_generation: task_generation
      ), dir
    end
  end

  def build_activity(writer:, task_folder: "/tmp/task", task_generation: 3)
    Hive::TaskActivity.new(
      task_folder: task_folder,
      task: { "id" => "42", "slug" => "durable-task" },
      workflow: "coding", stage: "4-execute", attempt_id: "attempt-1",
      task_generation: task_generation, ownership_generation: "ownership-1",
      commit_generation: 0, writer: writer, clock: -> { NOW }
    )
  end
end
