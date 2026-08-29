require "test_helper"
require "hive/task_activity"
require "hive/attempts/repository"

class TaskActivityTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 12, 12, 0, 0)

  def test_records_one_typed_authoritative_activity
    with_activity do |activity, dir, writer|
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

      checkpoint = File.join(dir, Hive::TaskProjection::Store::CHECKPOINT_BASENAME)
      assert File.file?(checkpoint), "a durable activity must publish the bounded-read checkpoint"
      projection = Hive::TaskProjection::Store.new(
        task_folder: dir, attempt_store: writer.attempt_store
      ).read_bounded
      assert_equal "current", projection.state
      assert_empty projection.diagnostics
    end
  end

  def test_checkpoint_refresh_failure_does_not_reject_a_durable_activity
    with_activity do |activity, dir|
      broken_store = Object.new
      broken_store.define_singleton_method(:rebuild!) { raise "checkpoint unavailable" }
      original_new = Hive::TaskProjection::Store.method(:new)
      Hive::TaskProjection::Store.define_singleton_method(:new) { |**| broken_store }
      begin
        result = activity.record(
          kind: "attempt_admitted", operation_id: "attempt/attempt-1/admitted",
          reason: "durable attempt admitted", source: "attempt_dispatcher"
        )
      ensure
        Hive::TaskProjection::Store.singleton_class.define_method(:new, original_new)
      end

      assert_equal "event-1", result.event_id
      assert_equal 1, File.readlines(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME)).size
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

  def test_operation_receipt_is_durable_before_mutation_and_completes_once
    with_activity do |activity, dir|
      operation = activity.begin_operation(
        kind: "decision_recorded", operation_id: "decision:visit-1:approve",
        source: "command_service", reason: "decision approved",
        precondition: { "decision" => "visit-1", "state" => "waiting" },
        expected_postcondition: { "state" => "complete" }
      )
      receipt_path = File.join(
        dir, Hive::TaskActivity::OPERATION_DIRECTORY,
        "#{Digest::SHA256.hexdigest(operation.operation_id)}.json"
      )
      pending = JSON.parse(File.read(receipt_path))
      assert_equal "pending", pending.fetch("state")
      assert_equal 0o600, File.stat(receipt_path).mode & 0o777

      first = operation.complete!(
        result: { "state" => "complete" },
        payload: { "decision" => "approve" }, occurred_at: NOW
      )
      completed = JSON.parse(File.read(receipt_path))
      assert_equal "complete", completed.fetch("state")
      assert_equal first.event_id, completed.fetch("event_id")

      summary = activity.reconcile_operations! { flunk "complete receipt must not resolve" }
      assert_equal 0, summary.fetch("completed")
      records = File.readlines(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME))
      assert_equal 1, records.length
    end
  end

  def test_committed_receipt_replays_missing_append_idempotently
    with_activity do |activity, dir|
      operation = activity.begin_operation(
        kind: "approval_recorded", operation_id: "approval:visit-2",
        source: "command_service", reason: "approval recorded",
        precondition: "waiting", expected_postcondition: "approved"
      )
      failing = Object.new
      failing.define_singleton_method(:record) { |**| raise Hive::TaskActivity::AppendFailed, "crash" }
      assert_raises(Hive::TaskActivity::AppendFailed) do
        operation.complete!(result: "approved", occurred_at: NOW, activity: failing)
      end

      receipt_path = Dir[File.join(dir, Hive::TaskActivity::OPERATION_DIRECTORY, "*.json")].first
      assert_equal "committed_pending_activity", JSON.parse(File.read(receipt_path)).fetch("state")
      first = activity.reconcile_operations! { flunk "committed receipt must replay directly" }
      second = activity.reconcile_operations! { flunk "completed receipt must be ignored" }

      assert_equal 1, first.fetch("completed")
      assert_equal 0, second.fetch("completed")
      record = JSON.parse(File.read(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME)))
      assert_equal "approval_recorded", record.dig("payload", "activity_kind")
    end
  end

  def test_conflicting_committed_receipt_restores_the_authoritative_event
    with_activity do |activity, dir|
      operation = activity.begin_operation(
        kind: "retry_requested", operation_id: "recovery:task-1",
        source: "recovery_service", reason: "recovery requested",
        precondition: "error", expected_postcondition: "evaluated"
      )
      operation.complete!(
        result: { "status" => "cooldown" },
        payload: { "outcome" => "cooldown", "retry_at" => "2026-08-17T01:00:00Z" },
        occurred_at: NOW
      )

      assert_raises(Hive::TaskActivity::Conflict) do
        operation.complete!(
          result: { "status" => "queued" },
          payload: { "outcome" => "queued", "retry_at" => "2026-08-17T01:00:00Z" },
          occurred_at: NOW + 60
        )
      end
      assert operation.committed?

      operation.restore_authoritative!

      assert operation.complete?
      assert_equal "cooldown", operation.receipt.dig("record_payload", "outcome")
      assert_equal 1, File.readlines(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME)).length
    end
  end

  def test_restore_authoritative_refuses_when_the_journal_does_not_corroborate
    with_activity do |activity, dir|
      operation = activity.begin_operation(
        kind: "retry_requested", operation_id: "recovery:task-2",
        source: "recovery_service", reason: "recovery requested",
        precondition: "error", expected_postcondition: "evaluated"
      )

      error = assert_raises(Hive::TaskActivity::Conflict) { operation.restore_authoritative! }

      assert_match(/authoritative activity does not match operation recovery:task-2/, error.message)
      refute operation.complete?
      refute File.exist?(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME))
    end
  end

  def test_restore_authoritative_refuses_when_the_journal_cannot_be_read
    with_activity do |activity, dir|
      operation = activity.begin_operation(
        kind: "retry_requested", operation_id: "recovery:task-3",
        source: "recovery_service", reason: "recovery requested",
        precondition: "error", expected_postcondition: "evaluated"
      )
      operation.complete!(
        result: { "status" => "cooldown" }, payload: { "outcome" => "cooldown" }, occurred_at: NOW
      )
      assert_raises(Hive::TaskActivity::Conflict) do
        operation.complete!(
          result: { "status" => "queued" }, payload: { "outcome" => "queued" }, occurred_at: NOW + 60
        )
      end
      journal = File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME)
      File.write(journal, "{not json\n", mode: "a")

      error = assert_raises(Hive::TaskActivity::Conflict) { operation.restore_authoritative! }

      assert_match(/authoritative activity recovery failed/, error.message)
      assert operation.committed?
      refute operation.complete?
    end
  end

  def test_pending_reconciliation_never_invents_success_and_appends_ambiguity_gap
    with_activity do |activity, dir|
      not_committed = activity.begin_operation(
        kind: "retry_requested", operation_id: "retry:not-committed",
        source: "recovery_service", reason: "retry requested",
        precondition: "blocked", expected_postcondition: "scheduled"
      )
      ambiguous = activity.begin_operation(
        kind: "operator_action", operation_id: "action:ambiguous",
        source: "operator", reason: "operator action",
        precondition: "waiting", expected_postcondition: "advanced"
      )
      summary = activity.reconcile_operations! do |receipt|
        receipt.fetch("operation_id") == not_committed.operation_id ? :not_committed : :ambiguous
      end

      assert_equal 1, summary.fetch("gaps")
      records = File.readlines(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME)).map do |line|
        JSON.parse(line)
      end
      assert_equal [ "activity_gap" ], records.map { |row| row.dig("payload", "activity_kind") }
      states = Dir[File.join(dir, Hive::TaskActivity::OPERATION_DIRECTORY, "*.json")].map do |path|
        JSON.parse(File.read(path)).fetch("state")
      end
      assert_equal %w[aborted gap], states.sort
    end
  end

  def test_operation_receipt_scan_is_bounded_and_refuses_symlinks
    with_activity do |activity, dir|
      activity.begin_operation(
        kind: "operator_action", operation_id: "action:one", source: "operator",
        reason: "action", precondition: "a", expected_postcondition: "b"
      )
      operations = File.join(dir, Hive::TaskActivity::OPERATION_DIRECTORY)
      File.symlink("/etc/passwd", File.join(operations, "#{'f' * 64}.json"))

      summary = activity.reconcile_operations!(max_receipts: 2, max_bytes: 128 * 1024) do
        :not_committed
      end

      assert_includes summary.fetch("diagnostics").map { |row| row.fetch("reason") },
                      "operation_receipt_invalid"
    end
  end

  def test_operation_receipt_cap_is_applied_after_terminal_receipts_are_skipped
    with_activity do |activity, _dir|
      ids = (1..20).map { |number| "action:cap-order:#{number}" }
                     .sort_by { |id| Digest::SHA256.hexdigest(id) }
      completed_ids = ids.first(2)
      pending_id = ids.last
      completed_ids.each do |operation_id|
        operation = activity.begin_operation(
          kind: "operator_action", operation_id: operation_id, source: "operator",
          reason: "action", precondition: "before", expected_postcondition: "after"
        )
        operation.complete!(result: "after", occurred_at: NOW)
      end
      activity.begin_operation(
        kind: "operator_action", operation_id: pending_id, source: "operator",
        reason: "action", precondition: "before", expected_postcondition: "after"
      )

      reconciled = []
      summary = activity.reconcile_operations!(max_receipts: 1) do |receipt|
        reconciled << receipt.fetch("operation_id")
        :not_committed
      end

      assert_equal [ pending_id ], reconciled
      assert_equal 1, summary.fetch("processed")
      refute_includes summary.fetch("diagnostics").map { |row| row["cap"] },
                      "operation_receipts"
    end
  end

  def test_aborted_operation_keeps_history_and_retry_gets_a_distinct_identity
    with_activity do |activity, dir|
      attributes = {
        kind: "retry_requested", operation_id: "retry:task-1",
        source: "recovery_service", reason: "retry requested",
        precondition: "blocked", expected_postcondition: "queued"
      }
      first = activity.begin_operation(**attributes)
      first.abort!(reason: "not committed")
      second = activity.begin_operation(**attributes)

      assert_equal "retry:task-1", first.operation_id
      assert_equal "retry:task-1:retry:1", second.operation_id
      assert_equal 2, Dir[File.join(dir, Hive::TaskActivity::OPERATION_DIRECTORY, "*.json")].length
      assert_equal "pending", second.receipt.fetch("state")
    end
  end

  def test_new_attempt_reconciles_and_retries_a_prior_pending_operation
    with_activity do |first_activity, dir, writer|
      attributes = {
        kind: "approval_recorded",
        operation_id: "approve:3-plan:4-execute:forward",
        source: "command_service",
        reason: "task stage approval recorded",
        precondition: { "stage" => "3-plan", "marker" => "complete" },
        expected_postcondition: { "stage" => "4-execute" }
      }
      first_activity.begin_operation(**attributes)
      create_retry_attempt(writer)
      retry_activity = build_activity(
        writer: writer, task_folder: dir, task_generation: 3,
        attempt_id: "attempt-2", ownership_generation: "ownership-2"
      )

      summary = retry_activity.reconcile_operations! { :not_committed }
      retried = retry_activity.begin_operation(**attributes)
      duplicate = retry_activity.begin_operation(**attributes)

      assert_empty summary.fetch("diagnostics")
      assert_equal "approve:3-plan:4-execute:forward:retry:1", retried.operation_id
      assert_equal retried.operation_id, duplicate.operation_id,
                   "the same successor attempt must reopen its retry receipt idempotently"
      assert_equal "attempt-2", retried.receipt.fetch("attempt_id")
      assert_equal "aborted", first_activity_receipt(dir).fetch("state")
    end
  end

  def test_reconciliation_rejects_a_receipt_with_no_durable_attempt_binding
    with_activity do |activity, dir|
      operation = activity.begin_operation(
        kind: "operator_action", operation_id: "action:forged-attempt",
        source: "operator", reason: "operator action",
        precondition: "waiting", expected_postcondition: "advanced"
      )
      path = File.join(
        dir, Hive::TaskActivity::OPERATION_DIRECTORY,
        "#{Digest::SHA256.hexdigest(operation.operation_id)}.json"
      )
      receipt = JSON.parse(File.read(path)).merge("attempt_id" => "missing-attempt")
      File.write(path, JSON.generate(receipt) + "\n")

      summary = activity.reconcile_operations! do
        flunk "an unbound operation receipt must not reach domain reconciliation"
      end

      assert_equal [ "operation_receipt_invalid" ],
                   summary.fetch("diagnostics").map { |row| row.fetch("reason") }
      assert_includes summary.dig("diagnostics", 0, "detail"), "unknown durable attempt"
    end
  end

  private

  def with_activity(task_generation: 3)
    with_tmp_dir do |dir|
      store = Hive::Attempts::Repository.new(root: File.join(dir, "attempts"), migrate: true)
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
      ), dir, writer
    end
  end

  def build_activity(writer:, task_folder: "/tmp/task", task_generation: 3,
                     attempt_id: "attempt-1", ownership_generation: "ownership-1")
    Hive::TaskActivity.new(
      task_folder: task_folder,
      task: { "id" => "42", "slug" => "durable-task" },
      workflow: "coding", stage: "4-execute", attempt_id: attempt_id,
      task_generation: task_generation, ownership_generation: ownership_generation,
      commit_generation: 0, writer: writer, clock: -> { NOW }
    )
  end

  def first_activity_receipt(dir)
    paths = Dir[File.join(dir, Hive::TaskActivity::OPERATION_DIRECTORY, "*.json")]
    receipts = paths.map { |path| JSON.parse(File.read(path)) }
    receipts.find { |receipt| receipt.fetch("operation_id") == "approve:3-plan:4-execute:forward" }
  end

  def create_retry_attempt(writer)
    writer.attempt_store.create_launching(
      attempt_id: "attempt-2", request_id: "request-2",
      predecessor_attempt_id: "attempt-1", task_id: "42", project: "demo",
      task_slug: "durable-task", intended_stage: "4-execute",
      task_generation: "ownership-2", ownership_generation: "ownership-2",
      task_input_epoch: 3, progress_token: "progress-2", provider: "codex",
      starting_revision: nil, worker_argv: [ "hive", "run", "durable-task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest("d" * 64),
      retry_charge: 1, inherited_outputs: [], launch_timeout_sec: 30, now: NOW
    )
  end
end
