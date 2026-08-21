require "test_helper"
require "tmpdir"
require "json_schemer"
require "pathname"
require "hive/patrol_fix/projection"

class PatrolFixProjectionTest < Minitest::Test
  def test_rejected_inbox_is_parked_and_non_runnable
    with_task do |dir, manifest, receipts|
      receipts.append!(decision_receipt(route: "reject", stage: "inbox"))

      projected = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "1-inbox").to_h

      assert_equal "current", projected.fetch("state")
      assert_equal "rejected", projected.dig("outcome", "kind")
      assert_equal "inbox_gate", projected.fetch("blocker_owner")
      assert_equal "parked", projected.dig("action", "kind")
      refute projected.dig("action", "runnable")
      assert JSONSchemer.schema(
        Pathname.new(Hive::Schemas.schema_path("hive-patrol-fix-projection"))
      ).valid?(projected)
    end
  end

  def test_escalated_task_projects_successor_and_stays_non_done
    with_task(successor: { "project" => "demo", "slug" => "coding-successor-260820-abcd" }) do |dir, _manifest, receipts|
      receipts.append!(decision_receipt(route: "escalate", stage: "inbox"))

      projected = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "1-inbox").to_h

      assert_equal "escalated", projected.dig("outcome", "kind")
      assert_equal({ "project" => "demo", "slug" => "coding-successor-260820-abcd" },
                   projected.fetch("successor"))
      refute projected.fetch("archived")
    end
  end

  def test_reopen_supersedes_only_the_current_parked_receipt
    with_task do |dir, _manifest, receipts|
      receipts.append!(decision_receipt(route: "blocked", stage: "review", id: "decision-1"))
      receipts.append!(reopen_receipt(outcome_receipt_id: "decision-1"))

      projected = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "4-review").to_h

      assert_nil projected.fetch("outcome")
      assert_equal "ready", projected.dig("action", "kind")
      assert projected.dig("action", "runnable")
    end
  end

  def test_same_generation_cannot_write_a_second_decision_after_reopen
    with_task do |dir, _manifest, receipts|
      receipts.append!(decision_receipt(route: "blocked", stage: "review", id: "decision-1"))
      receipts.append!(reopen_receipt(outcome_receipt_id: "decision-1"))
      assert_raises(Hive::PatrolFix::ReceiptStore::InvalidReceipt) do
        receipts.append!(decision_receipt(route: "reject", stage: "review", id: "decision-2"))
      end
    end
  end

  def test_done_requires_an_exact_current_publication_receipt
    with_task do |dir, _manifest, receipts|
      missing = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "6-done").to_h
      assert_equal "invalid", missing.fetch("state")
      refute missing.fetch("archived")
      assert_includes missing.dig("diagnostic", "summary"), "pull-request receipt"

      receipts.append!(publication_receipt)
      done = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "6-done").to_h
      assert_equal "current", done.fetch("state")
      assert done.fetch("archived")
      assert_equal "https://github.com/acme/demo/pull/42", done.dig("publication", "url")
      assert_equal "done", done.dig("action", "kind")
    end
  end

  def test_last_semantic_decision_remains_visible_after_the_task_advances
    with_task do |dir, _manifest, receipts|
      receipts.append!(decision_receipt(route: "fix", stage: "inbox"))

      projected = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "2-fix").to_h

      assert_equal "decision-1", projected.dig("decision", "receipt_id")
      assert_equal "inbox", projected.dig("decision", "stage")
      assert_equal "fix", projected.dig("decision", "payload", "route")
      assert_nil projected.fetch("outcome")
    end
  end

  def test_materially_changed_evidence_invalidates_old_decisions_and_publication
    with_task do |dir, manifest, receipts|
      receipts.append!(decision_receipt(route: "reject", stage: "inbox"))
      receipts.append!(publication_receipt)

      changed = manifest.read
      changed = Marshal.load(Marshal.dump(changed))
      changed.fetch("task")["generation"] = 2
      changed.fetch("evidence_revision").merge!("generation" => 2, "digest" => "b" * 64)
      manifest.write!(changed)

      inbox = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "1-inbox").to_h
      assert_nil inbox.fetch("outcome")
      assert_equal "ready", inbox.dig("action", "kind")

      done = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "6-done").to_h
      assert_equal "invalid", done.fetch("state")
      refute done.fetch("archived")
    end
  end

  def test_invalid_artifacts_surface_a_bounded_diagnostic
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, Hive::PatrolFix::TaskManifest::FILENAME), "not-json")

      projected = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "1-inbox").to_h

      assert_equal "invalid", projected.fetch("state")
      assert_operator projected.dig("diagnostic", "summary").bytesize, :<=,
                      Hive::PatrolFix::Projection::MAX_DIAGNOSTIC_BYTES
      refute projected.dig("action", "runnable")
    end
  end

  def test_fix_routed_inbox_is_ready_to_advance_only_while_still_in_inbox
    with_task do |dir, _manifest, receipts|
      receipts.append!(decision_receipt(route: "fix", stage: "inbox"))
      inbox = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "1-inbox").to_h
      assert_equal "advance", inbox.dig("action", "kind")
      assert inbox.dig("action", "runnable")

      fix = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "2-fix").to_h
      assert_equal "ready", fix.dig("action", "kind")
    end
  end

  def test_timing_projects_durable_receipt_boundaries_and_parked_intervals
    with_task do |dir, _manifest, receipts|
      receipts.append!(decision_receipt(route: "blocked", stage: "review", id: "decision-1"))
      receipts.append!(reopen_receipt(outcome_receipt_id: "decision-1"))

      projected = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "4-review").to_h

      assert_equal "2026-08-20T12:00:00Z", projected.dig("timing", "started_at")
      assert_equal 60, projected.dig("timing", "parked_seconds")
      assert_nil projected.dig("timing", "parked_since")
      assert_equal 0, projected.dig("timing", "rework_count")
    end
  end

  def test_invalid_publication_diagnostics_fail_the_projection_closed
    with_task do |dir, _manifest, _receipts|
      path = File.join(dir, "patrol-fix-publication-diagnostic.json")
      File.write(path, JSON.generate("schema" => "unknown"))
      invalid = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "1-inbox").to_h
      assert_equal "invalid", invalid.fetch("state")
      assert_includes invalid.dig("diagnostic", "summary"), "diagnostic is invalid"

      File.write(path, "{")
      malformed = Hive::PatrolFix::Projection.new(task_folder: dir, stage: "1-inbox").to_h
      assert_equal "invalid", malformed.fetch("state")
      assert_includes malformed.dig("diagnostic", "summary"), "JSON::ParserError"
    end
  end

  def test_action_defaults_to_not_ready_for_an_unrecognized_internal_stage
    projection = Hive::PatrolFix::Projection.new(task_folder: ".", stage: "future")

    action = projection.send(
      :action_for, state: "current", done: false, outcome: nil,
      decision: nil, fix: nil, validation: nil, publication: nil
    )

    assert_equal({ "kind" => "ready", "runnable" => true }, action)
  end

  private

  def with_task(successor: nil)
    Dir.mktmpdir do |dir|
      manifest = Hive::PatrolFix::TaskManifest.new(task_folder: dir)
      manifest.write!(
        "schema" => "hive-patrol-fix-task-manifest",
        "schema_version" => 1,
        "task" => { "slug" => "repair-login-260820-abcd", "generation" => 1 },
        "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 },
        "target_revision" => "1" * 40,
        "sources" => [ {
          "engine" => "ordinary_patrol", "identity" => "finding-1", "target_revision" => "1" * 40,
          "evidence" => [ "reachable" ], "affected_code" => [ "lib/demo.rb" ],
          "reproduction_guidance" => "Run the focused test.", "discovery_run" => "run-1",
          "semantic_lineage" => [ "root-1" ]
        } ],
        "aliases" => [],
        "relations" => { "successor" => successor, "issues" => [] }
      )
      receipts = Hive::PatrolFix::ReceiptStore.new(task_folder: dir)
      yield dir, manifest, receipts
    end
  end

  def decision_receipt(route:, stage:, id: "decision-1")
    {
      "schema" => "hive-patrol-fix-receipt", "schema_version" => 1,
      "receipt_id" => id, "kind" => "decision", "stage" => stage,
      "task" => { "slug" => "repair-login-260820-abcd", "generation" => 1 },
      "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 },
      "recorded_at" => "2026-08-20T12:00:00Z",
      "payload" => {
        "route" => route, "rationale" => "Current semantic decision.",
        "evidence" => [ "bounded evidence" ], "blocker_owner" => "#{stage}_gate",
        "head_revision" => "b" * 40
      }.tap do |payload|
        payload.merge!(
          "diff_digest" => "c" * 64,
          "fix_receipt_id" => "fix-1", "validation_receipt_id" => "validation-1"
        ) if stage == "review"
      end
    }
  end

  def reopen_receipt(outcome_receipt_id:)
    {
      "schema" => "hive-patrol-fix-receipt", "schema_version" => 1,
      "receipt_id" => "reopen-1", "kind" => "reopen", "stage" => "review",
      "task" => { "slug" => "repair-login-260820-abcd", "generation" => 1 },
      "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 },
      "recorded_at" => "2026-08-20T12:01:00Z",
      "payload" => {
        "outcome_receipt_id" => outcome_receipt_id, "operator" => "cli:test",
        "carried_receipts" => []
      }
    }
  end

  def publication_receipt
    Hive::PatrolFix::PublicationReceipt.build(
      task: { "slug" => "repair-login-260820-abcd", "generation" => 1 },
      evidence_revision: { "generation" => 1, "digest" => "a" * 64 },
      publication: {
        "publication_id" => "pub-#{'1' * 32}", "number" => 42,
        "url" => "https://github.com/acme/demo/pull/42",
        "host" => "github.com", "repository" => "acme/demo",
        "base_branch" => "main", "creation_base_oid" => "1" * 40,
        "branch" => "hive/repair-login", "head_oid" => "2" * 40,
        "diff_digest" => "3" * 64, "title_digest" => "4" * 64,
        "body_digest" => "5" * 64, "marker_digest" => "6" * 64,
        "hosted_state" => "open", "observed_at" => "2026-08-20T12:02:00Z"
      }
    )
  end
end
