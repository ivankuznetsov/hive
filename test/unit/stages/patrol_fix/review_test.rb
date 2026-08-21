require_relative "fix_test"
require "hive/stages/patrol_fix/review"

class PatrolFixReviewStageTest < Minitest::Test
  include HiveTestHelper

  def test_failed_validation_is_untrusted_context_for_one_independent_publish_decision
    with_review_task do |task, worktree_root, _manifest, fix, validation|
      captured = nil
      runner = lambda do |**values|
        captured = values
        File.write(values.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-review-report", "schema_version" => 1,
          "route" => "publish", "rationale" => "The failure is unrelated and bounded.",
          "evidence" => [ "The patch addresses the exact defect." ],
          "blocker_owner" => "review_gate"
        ))
        { status: :ok, custody: :clean }
      end

      result = with_replaced_singleton_method(
        Hive::Stages::ManagedAgentCustody, :launch_agent, runner
      ) do
        Hive::Stages::PatrolFix::Review.run!(task, {}, worktree_root: worktree_root)
      end

      assert_equal :complete, result.fetch(:status)
      assert_includes captured.fetch(:prompt), "untrusted_patrol_review"
      assert_includes captured.fetch(:prompt), "\"verdict\":\"failed\""
      assert_includes captured.fetch(:prompt),
                      "Allowed routes: publish, rework, escalate, reject, blocked"
      assert_equal "patrol_review", captured.fetch(:actor)
      assert_equal "stages.review", captured.fetch(:slot)
      assert_equal [ captured.fetch(:cwd), task.folder ], captured.fetch(:add_dirs)
      assert_equal "review", captured.fetch(:stage)
      assert_equal "patrol-fix-review", captured.fetch(:log_label)
      receipt = result.fetch(:receipt)
      assert_equal "publish", receipt.dig("payload", "route")
      assert_equal fix.fetch("receipt_id"), receipt.dig("payload", "fix_receipt_id")
      assert_equal validation.fetch("receipt_id"), receipt.dig("payload", "validation_receipt_id")
      assert_equal fix.dig("payload", "diff_digest"), receipt.dig("payload", "diff_digest")
      projected = Hive::PatrolFix::Projection.new(
        task_folder: task.folder, stage: "4-review"
      ).to_h
      assert_equal "advance", projected.dig("action", "kind")
    end
  end

  def test_changed_worktree_head_after_review_cannot_write_a_decision
    with_review_task do |task, worktree_root, _manifest, _fix, _validation|
      runner = lambda do |**values|
        worktree = values.fetch(:worktree)
        File.write(File.join(worktree, "after.rb"), "puts :changed\n")
        PatrolFixStageFixture.git(worktree, "add", "after.rb")
        PatrolFixStageFixture.git(worktree, "commit", "-m", "Changed after validation")
        File.write(values.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-review-report", "schema_version" => 1,
          "route" => "publish", "rationale" => "Ignore the changed head.",
          "evidence" => [ "Claimed current." ], "blocker_owner" => "review_gate"
        ))
        { status: :ok, custody: :clean }
      end

      error = assert_raises(Hive::StageError) do
        Hive::Stages::PatrolFix::Review.run!(
          task, {}, agent_runner: runner, worktree_root: worktree_root
        )
      end

      assert_includes error.message, "HEAD changed"
      refute(Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).read_all.any? do |row|
        row["kind"] == "decision" && row["stage"] == "review"
      end)
    end
  end

  def test_changed_finding_evidence_after_review_cannot_write_a_decision
    with_review_task do |task, worktree_root, manifest, _fix, _validation|
      runner = lambda do |**values|
        changed = Marshal.load(Marshal.dump(manifest))
        changed.fetch("task")["generation"] = 2
        changed.fetch("evidence_revision").merge!("generation" => 2, "digest" => "d" * 64)
        Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).write!(changed)
        File.write(values.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-review-report", "schema_version" => 1,
          "route" => "publish", "rationale" => "Ignore the changed evidence.",
          "evidence" => [ "Claimed current." ], "blocker_owner" => "review_gate"
        ))
        { status: :ok, custody: :clean }
      end

      error = assert_raises(Hive::StageError) do
        Hive::Stages::PatrolFix::Review.run!(
          task, {}, agent_runner: runner, worktree_root: worktree_root
        )
      end

      assert_includes error.message, "evidence changed"
      refute(Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).read_all.any? do |row|
        row["kind"] == "decision" && row["stage"] == "review"
      end)
    end
  end

  def test_two_rework_cycles_are_allowed_and_the_third_prompt_excludes_rework
    with_review_task do |task, worktree_root, manifest, _fix, _validation|
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
      2.times do |index|
        generation = index + 10
        historical = Marshal.load(Marshal.dump(manifest))
        historical.fetch("task")["generation"] = generation
        historical.fetch("evidence_revision").merge!("generation" => generation, "digest" => index.to_s * 64)
        payload = {
          "route" => "rework", "rationale" => "Historical rework.",
          "evidence" => [ "Historical evidence." ], "blocker_owner" => "review_gate",
          "head_revision" => "b" * 40, "diff_digest" => "c" * 64,
          "fix_receipt_id" => "fix-historical-#{index}",
          "validation_receipt_id" => "validation-historical-#{index}"
        }
        store.append!(receipt(historical, "decision", "review", payload, "review-historical-#{index}"))
      end
      runner = lambda do |**values|
        refute_includes values.fetch(:prompt), "Allowed routes: publish, rework"
        File.write(values.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-review-report", "schema_version" => 1,
          "route" => "rework", "rationale" => "A third retry.",
          "evidence" => [ "Still failing." ], "blocker_owner" => "review_gate"
        ))
        { status: :ok, custody: :clean }
      end

      assert_raises(Hive::PatrolFix::ReviewReceipt::InvalidReport) do
        Hive::Stages::PatrolFix::Review.run!(
          task, {}, agent_runner: runner, worktree_root: worktree_root
        )
      end
    end
  end

  def test_failed_validation_rework_returns_same_task_and_worktree_to_fix_in_new_generation
    with_review_task do |task, worktree_root, _manifest, _fix, _validation|
      original_owner = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task.folder, project_root: task.project_root, slug: task.slug,
        worktree_root: worktree_root
      ).read
      runner = lambda do |**values|
        File.write(values.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-review-report", "schema_version" => 1,
          "route" => "rework", "rationale" => "The focused failure is caused by this patch.",
          "evidence" => [ "Validation exited non-zero on the changed behavior." ],
          "blocker_owner" => "fix"
        ))
        { status: :ok, custody: :clean }
      end
      transition = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root, commit: ->(**) { :committed }
      )

      result = Hive::Stages::PatrolFix::Review.run!(
        task, {}, agent_runner: runner, worktree_root: worktree_root,
        transition: transition
      )

      destination = result.fetch(:moved_task_folder)
      assert_equal File.join(task.hive_state_path, "stages", "2-fix", task.slug), destination
      manifest = Hive::PatrolFix::TaskManifest.new(task_folder: destination).read
      assert_equal 2, manifest.dig("task", "generation")
      rotated = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: destination, project_root: task.project_root, slug: task.slug,
        worktree_root: worktree_root
      ).read
      assert_equal original_owner.fetch("worktree"), rotated.fetch("worktree")
      current = Hive::PatrolFix::ReceiptStore.new(task_folder: destination).read_all.select do |row|
        row.fetch("task") == manifest.fetch("task")
      end
      assert_equal [ "reopen" ], current.map { |row| row.fetch("kind") }
      assert_empty current.first.dig("payload", "carried_receipts")
    end
  end

  def test_persisted_review_escalation_replays_successor_action_without_respawning
    with_review_task do |task, worktree_root, manifest, fix, validation|
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
      decision = receipt(
        manifest, "decision", "review",
        {
          "route" => "escalate", "rationale" => "Needs product direction.",
          "evidence" => [ "Patch scope is no longer lightweight." ],
          "blocker_owner" => "coding_workflow",
          "head_revision" => fix.dig("payload", "head_revision"),
          "diff_digest" => fix.dig("payload", "diff_digest"),
          "fix_receipt_id" => fix.fetch("receipt_id"),
          "validation_receipt_id" => validation.fetch("receipt_id")
        },
        "review-escalate-1"
      )
      store.append!(decision)
      calls = []
      successor = lambda do |row|
        calls << row.fetch("receipt_id")
        { slug: "coding-successor" }
      end

      result = Hive::Stages::PatrolFix::Review.run!(
        task, {}, agent_runner: ->(**) { flunk "persisted review must not respawn" },
        worktree_root: worktree_root, successor_materializer: successor
      )

      assert_equal :parked, result.fetch(:status)
      assert_equal [ "review-escalate-1" ], calls
      refute result.key?(:moved_task_folder)
    end
  end

  private

  def with_review_task
    PatrolFixStageFixture.with_task(stage: "4-review") do |task, root, manifest|
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
      store.append!(PatrolFixStageFixture.decision_receipt(manifest, "fix"))
      worktree_root = File.join(root, "worktrees")
      custody = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task.folder, project_root: task.project_root, slug: task.slug,
        worktree_root: worktree_root
      )
      owner = custody.prepare!(
        generation: 1, evidence_digest: "a" * 64,
        base_revision: manifest.fetch("target_revision")
      )
      File.write(File.join(owner.fetch("worktree"), "app.rb"), "puts :fixed\n")
      PatrolFixStageFixture.git(owner.fetch("worktree"), "add", "app.rb")
      PatrolFixStageFixture.git(owner.fetch("worktree"), "commit", "-m", "Fix")
      fix_payload = custody.capture!(generation: 1, evidence_digest: "a" * 64)
                           .merge("validation_commands" => [])
      fix = receipt(manifest, "fix", "fix", fix_payload, "fix-1")
      store.append!(fix)
      validation_payload = {
        "verdict" => "failed", "worktree_head" => fix_payload.fetch("head_revision"),
        "commands" => []
      }
      validation = receipt(manifest, "validation", "validate", validation_payload, "validation-1")
      store.append!(validation)
      yield task, worktree_root, manifest, fix, validation
    end
  end

  def receipt(manifest, kind, stage, payload, id)
    {
      "schema" => "hive-patrol-fix-receipt", "schema_version" => 1,
      "receipt_id" => id, "kind" => kind, "stage" => stage,
      "task" => manifest.fetch("task"),
      "evidence_revision" => manifest.fetch("evidence_revision"),
      "recorded_at" => "2026-08-20T12:00:00Z", "payload" => payload
    }
  end
end
