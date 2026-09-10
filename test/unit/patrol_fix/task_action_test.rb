require "test_helper"
require "fileutils"
require "tmpdir"
require "hive/daemon/policy"
require "hive/markers"
require "hive/operational_action"
require "hive/commands/status"
require "hive/tui/snapshot"
require "hive/bot/status_watcher"
require "hive/patrol_fix/receipt_store"
require "hive/patrol_fix/publication_block_receipt"
require "hive/patrol_fix/task_manifest"
require "hive/task"
require "hive/task_action"

class PatrolFixTaskActionTest < Minitest::Test
  include HiveTestHelper

  SLUG = "repair-login-260820-abcd"
  Marker = Hive::Markers::State

  def test_rejection_advances_to_archive_while_blocked_remains_parked
    with_task("inbox") do |task, receipts|
      receipts.append!(decision_receipt(route: "reject", stage: "inbox"))

      action = Hive::TaskAction.for(task, marker)

      assert_equal Hive::Schemas::TaskActionKind::READY_TO_ADVANCE, action.key
      assert_includes action.command, "hive approve"
      assert_equal "rejected", action.patrol_fix.dig("outcome", "kind")
      assert_equal :dispatch, policy_decision(action)
    end

    with_task("review") do |task, receipts|
      receipts.append!(decision_receipt(route: "blocked", stage: "review"))

      action = Hive::TaskAction.for(task, marker)

      assert_equal Hive::Schemas::TaskActionKind::PATROL_FIX_BLOCKED, action.key
      assert_equal "review_gate", action.patrol_fix.fetch("blocker_owner")
      assert_nil action.command
      assert_equal :skip, policy_decision(action)
    end
  end

  def test_escalation_dispatches_the_archive_transition
    with_task("inbox", successor: { "project" => "demo", "slug" => "coding-successor-260820-abcd" }) do |task, receipts|
      receipts.append!(decision_receipt(route: "escalate", stage: "inbox"))

      action = Hive::TaskAction.for(task, marker)

      assert_equal Hive::Schemas::TaskActionKind::READY_TO_ADVANCE, action.key
      assert_equal({ "project" => "demo", "slug" => "coding-successor-260820-abcd" },
                   action.patrol_fix.fetch("successor"))
      refute action.patrol_fix.fetch("archived")
      assert_equal :dispatch, policy_decision(action)
    end
  end

  def test_done_is_an_error_until_an_exact_publication_receipt_exists
    with_task("done") do |task, receipts|
      missing = Hive::TaskAction.for(task, marker)
      assert_equal Hive::Schemas::TaskActionKind::ERROR, missing.key
      refute missing.patrol_fix.fetch("archived")

      receipts.append!(publication_receipt)
      done = Hive::TaskAction.for(task, marker)
      assert_equal Hive::Schemas::TaskActionKind::ARCHIVED, done.key
      assert done.patrol_fix.fetch("archived")
      assert_equal "github:acme/demo#42", done.patrol_fix.dig("publication", "id")
    end
  end

  def test_publication_secret_block_exposes_only_the_receipt_bound_operator_rework
    with_task("publish") do |task, receipts, root|
      block = publication_block_receipt
      receipts.append!(block)
      action = Hive::TaskAction.for(task, marker)

      assert_equal Hive::Schemas::TaskActionKind::PATROL_FIX_PUBLICATION_BLOCKED,
                   action.key
      assert_equal "Publication blocked by secret policy", action.label
      assert_nil action.command
      assert_equal :skip, policy_decision(action)

      descriptor = Hive::OperationalAction.descriptor_for_task(task, project: "demo")
      assert_equal "patrol_fix.rework_publication", descriptor.fetch("action_id")
      assert_raises(Hive::StaleOperationalObservation) do
        Hive::OperationalAction.assert_current!(
          task, project: "demo", action_id: "workflow.retry",
          target: descriptor.fetch("target"),
          observation_token: descriptor.fetch("observation_token")
        )
      end

      project = {
        "name" => "demo", "path" => root,
        "hive_state_path" => File.join(root, ".hive-state")
      }
      status = Hive::Commands::Status.new(json: true)
      payload = status.json_payload([ project ], now: Time.utc(2026, 8, 20, 12, 5))
      row = payload.dig("projects", 0, "tasks", 0)
      assert_equal "patrol_fix_publication_blocked", row.fetch("action")
      assert_equal block.fetch("receipt_id"), row.fetch("action_receipt_id")

      operational = status.operational_payload(
        [ project ], status_payload: payload, scheduler_snapshot: nil,
        now: Time.utc(2026, 8, 20, 12, 5)
      ).fetch("tasks").first
      assert_equal "waiting_on_you", operational.fetch("state")
      assert_equal "operator", operational.fetch("blocker_owner")
      assert_equal "secret_detected", operational.dig("reasons", 0, "code")
      assert_equal "patrol_fix.rework_publication",
                   operational.dig("action", "action_id")
      assert_equal descriptor.fetch("observation_token"),
                   operational.dig("action", "observation_token")
    end
  end

  def test_status_consumers_use_the_frozen_standard_task_contract
    with_task("review") do |task, receipts, root|
      receipts.append!(decision_receipt(route: "blocked", stage: "review"))
      project = {
        "name" => "demo", "path" => root,
        "hive_state_path" => File.join(root, ".hive-state")
      }
      status = Hive::Commands::Status.new(json: true)
      payload = status.json_payload([ project ], now: Time.utc(2026, 8, 20, 12, 5))
      row = payload.dig("projects", 0, "tasks", 0)

      assert_equal "needs_input", row.fetch("action")
      refute row.key?("patrol_fix")

      operational = status.operational_payload(
        [ project ], status_payload: payload, scheduler_snapshot: nil,
        now: Time.utc(2026, 8, 20, 12, 5)
      ).fetch("tasks").first
      refute operational.key?("patrol_fix")
      assert_equal "completion_ready", operational.fetch("state")
      assert_equal "none", operational.fetch("blocker_owner")
      assert_equal "terminal_parked", operational.dig("reasons", 0, "code")

      tui_row = Hive::Tui::Snapshot.from_payload(payload).rows.first
      assert_equal "needs_input", tui_row.action_key

      bot_row = Hive::Bot::StatusWatcher.new.send(
        :extract_rows, payload, now: Time.utc(2026, 8, 20, 12, 5)
      ).first
      assert_equal "needs_input", bot_row.action
      assert_equal task.slug, bot_row.slug
    end
  end

  private

  def marker
    Marker.new(name: :none, attrs: {}, raw: nil)
  end

  def with_task(stage_name, successor: nil)
    Dir.mktmpdir do |root|
      stage = Hive::Workflows::PatrolFix::DESCRIPTOR.stage_named(stage_name)
      folder = File.join(root, ".hive-state", "stages", stage.dir, SLUG)
      FileUtils.mkdir_p(folder)
      File.write(File.join(root, ".hive-state", "config.yml"), Hive::Config::DEFAULTS.to_yaml)
      File.write(File.join(folder, "meta.yml"), { "slug" => SLUG, "workflow" => "patrol-fix" }.to_yaml)
      Hive::PatrolFix::TaskManifest.new(task_folder: folder).write!(
        "schema" => "hive-patrol-fix-task-manifest", "schema_version" => 1,
        "task" => { "slug" => SLUG, "generation" => 1 },
        "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 },
        "target_revision" => "1" * 40,
        "sources" => [ {
          "engine" => "ordinary_patrol", "identity" => "finding-1", "target_revision" => "1" * 40,
          "evidence" => [ "reachable" ], "affected_code" => [ "lib/demo.rb" ],
          "reproduction_guidance" => "Run the focused test.", "discovery_run" => "run-1",
          "semantic_lineage" => [ "root-1" ]
        } ],
        "aliases" => [], "relations" => { "successor" => successor, "issues" => [] }
      )
      task = Hive::Task.new(folder)
      yield task, Hive::PatrolFix::ReceiptStore.new(task_folder: folder), root
    end
  end

  def decision_receipt(route:, stage:, id: "decision-1")
    {
      "schema" => "hive-patrol-fix-receipt", "schema_version" => 1,
      "receipt_id" => id, "kind" => "decision", "stage" => stage,
      "task" => { "slug" => SLUG, "generation" => 1 },
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

  def publication_receipt
    {
      "schema" => "hive-patrol-fix-receipt", "schema_version" => 1,
      "receipt_id" => "publication-1", "kind" => "publication", "stage" => "publish",
      "task" => { "slug" => SLUG, "generation" => 1 },
      "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 },
      "recorded_at" => "2026-08-20T12:02:00Z",
      "payload" => {
        "id" => "github:acme/demo#42", "publication_id" => "pub-#{'1' * 32}",
        "number" => 42, "url" => "https://github.com/acme/demo/pull/42",
        "host" => "github.com", "repository" => "acme/demo",
        "base_branch" => "main", "creation_base_revision" => "1" * 40,
        "branch" => "hive/repair-login", "head_revision" => "2" * 40,
        "diff_digest" => "3" * 64, "title_digest" => "4" * 64,
        "body_digest" => "5" * 64, "marker_digest" => "6" * 64,
        "state" => "open", "observed_at" => "2026-08-20T12:02:00Z"
      }
    }
  end

  def publication_block_receipt
    Hive::PatrolFix::PublicationBlockReceipt.build(
      task: { "slug" => SLUG, "generation" => 1 },
      evidence_revision: { "generation" => 1, "digest" => "a" * 64 },
      blocked_fields: [ "body" ], rework_stage: "review",
      review_receipt_id: "review-1", fix_receipt_id: "fix-1",
      validation_receipt_id: "validation-1", head_revision: "2" * 40,
      diff_digest: "3" * 64, recorded_at: Time.utc(2026, 8, 20, 12, 2)
    )
  end

  def policy_decision(action)
    Hive::Daemon::Policy.decide(
      action: action.key, stage: "#{action.task.stage_index}-#{action.task.stage_name}",
      workflow: action.task.workflow.id.to_s, command: action.command,
      state_file_mtime: Time.utc(2026, 8, 20, 12),
      last_dispatched_state_file_mtime: nil, now: Time.utc(2026, 8, 20, 12, 1)
    )
  end
end
