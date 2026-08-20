require "test_helper"
require "hive/patrol_fix/transition"
require_relative "../stages/patrol_fix/fix_test"

class PatrolFixTransitionTest < Minitest::Test
  def test_rework_persists_intent_advances_generation_rotates_custody_and_moves_same_task
    with_review_task(route: "rework") do |task, worktree_root, decision|
      commits = []
      transition = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root,
        commit: ->(**values) { commits << values }
      )

      result = transition.apply_review!(decision)

      destination = File.join(task.hive_state_path, "stages", "2-fix", task.slug)
      assert_equal destination, result.fetch(:task_folder)
      assert File.directory?(destination)
      manifest = Hive::PatrolFix::TaskManifest.new(task_folder: destination).read
      assert_equal 2, manifest.dig("task", "generation")
      refute_equal "a" * 64, manifest.dig("evidence_revision", "digest")
      owner = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: destination, project_root: task.project_root, slug: task.slug,
        worktree_root: worktree_root
      ).read
      assert_equal 2, owner.fetch("generation")
      assert File.file?(File.join(destination, "patrol-fix-worktrees", "generation-1.json"))
      receipts = Hive::PatrolFix::ReceiptStore.new(task_folder: destination).read_all
      authorization = receipts.find { |row| row["kind"] == "reopen" && row.dig("task", "generation") == 2 }
      assert_equal decision.fetch("receipt_id"), authorization.dig("payload", "outcome_receipt_id")
      assert_equal 1, commits.length
    end
  end

  def test_reopen_creates_a_new_generation_and_rebinds_current_review_evidence
    with_review_task(route: "blocked") do |task, worktree_root, decision|
      transition = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root, commit: ->(**) { :committed }
      )

      transition.reopen!(outcome_receipt_id: decision.fetch("receipt_id"), operator: "action")

      manifest = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read
      assert_equal 2, manifest.dig("task", "generation")
      receipts = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).read_all
      current = receipts.select { |row| row.dig("task", "generation") == 2 }
      assert_equal %w[reopen], current.map { |row| row.fetch("kind") }
      assert_equal %w[fix-1 validation-1], current.first.dig("payload", "carried_receipts")
      projected = Hive::PatrolFix::Projection.new(
        task_folder: task.folder, stage: "4-review"
      ).to_h
      assert_nil projected.fetch("outcome")
      assert_equal "ready", projected.dig("action", "kind")
    end
  end

  def test_rework_recovery_runs_fix_from_controller_authorization_without_a_second_review
    with_review_task(route: "rework") do |task, worktree_root, decision|
      result = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root, commit: ->(**) { :committed }
      ).apply_review!(decision)
      moved = Hive::Task.new(result.fetch(:task_folder))
      runner = lambda do |**values|
        worktree = values.fetch(:owner).fetch("worktree")
        File.write(File.join(worktree, "app.rb"), "puts :reworked\n")
        PatrolFixStageFixture.git(worktree, "add", "app.rb")
        PatrolFixStageFixture.git(worktree, "commit", "-m", "Rework")
        File.write(values.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-fix-report", "schema_version" => 1,
          "status" => "fixed", "summary" => "Reworked current patch.",
          "validation_commands" => []
        ))
        { status: :ok, custody: :clean }
      end

      fixed = Hive::Stages::PatrolFix::Fix.run!(
        moved, {}, agent_runner: runner, worktree_root: worktree_root
      )

      assert_equal :complete, fixed.fetch(:status)
      assert_equal 2, fixed.dig(:receipt, "task", "generation")
      assert_equal "reworked", File.read(File.join(
        fixed.dig(:receipt, "payload", "worktree"), "app.rb"
      )).match(/:(\w+)/)[1]
    end
  end

  def test_stale_review_cannot_transition_a_newer_generation
    with_review_task(route: "rework") do |task, worktree_root, decision|
      store = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder)
      newer = Marshal.load(Marshal.dump(store.read))
      newer.fetch("task")["generation"] = 2
      newer.fetch("evidence_revision").merge!("generation" => 2, "digest" => "b" * 64)
      store.write!(newer)

      error = assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        Hive::PatrolFix::Transition.new(
          task, worktree_root: worktree_root, commit: ->(**) { flunk "must not commit" }
        ).apply_review!(decision)
      end

      assert_includes error.message, "stale"
      assert_equal 2, store.read.dig("task", "generation")
      refute File.exist?(File.join(
        task.hive_state_path, "patrol-fix", "transitions", task.slug, "route-intent.json"
      ))
    end
  end

  def test_crash_after_generation_advance_and_folder_move_reconciles_without_redeciding
    with_review_task(route: "rework") do |task, worktree_root, decision|
      attempts = 0
      crashing_commit = lambda do |**|
        attempts += 1
        raise "crash before route acknowledgement" if attempts == 1
      end
      transition = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root, commit: crashing_commit
      )

      assert_raises(RuntimeError) { transition.apply_review!(decision) }
      destination = File.join(task.hive_state_path, "stages", "2-fix", task.slug)
      assert File.directory?(destination)
      assert_equal 2, Hive::PatrolFix::TaskManifest.new(task_folder: destination).read.dig("task", "generation")

      recovered = Hive::PatrolFix::Transition.new(
        Hive::Task.new(destination), worktree_root: worktree_root,
        commit: ->(**) { attempts += 1 }
      ).reconcile!

      assert_equal destination, recovered.fetch(:task_folder)
      assert_equal 2, attempts
      receipts = Hive::PatrolFix::ReceiptStore.new(task_folder: destination).read_all
      assert_equal 1, receipts.count { |row| row["kind"] == "reopen" }
      intent = JSON.parse(File.read(File.join(
        task.hive_state_path, "patrol-fix", "transitions", task.slug, "route-intent.json"
      )))
      assert_equal "completed", intent.fetch("status")
    end
  end

  def test_review_reopen_crash_replays_generation_and_evidence_carry_once
    with_review_task(route: "blocked") do |task, worktree_root, decision|
      attempts = 0
      commit = lambda do |**|
        attempts += 1
        raise "crash before reopen acknowledgement" if attempts == 1
      end
      transition = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root, commit: commit
      )

      assert_raises(RuntimeError) do
        transition.reopen!(
          outcome_receipt_id: decision.fetch("receipt_id"), operator: "action"
        )
      end
      assert_equal 2, Hive::PatrolFix::TaskManifest.new(
        task_folder: task.folder
      ).read.dig("task", "generation")

      recovered = transition.reconcile!

      assert_equal task.folder, recovered.fetch(:task_folder)
      assert_equal 2, attempts
      receipts = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).read_all
      current = receipts.select { |row| row.dig("task", "generation") == 2 }
      assert_equal 1, current.count { |row| row["kind"] == "reopen" }
      assert_equal %w[fix-1 validation-1], current.first.dig("payload", "carried_receipts")
    end
  end

  private

  def with_review_task(route:)
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
      validation_payload = { "verdict" => "failed", "worktree_head" => fix_payload.fetch("head_revision"), "commands" => [] }
      store.append!(receipt(manifest, "validation", "validate", validation_payload, "validation-1"))
      decision = receipt(
        manifest, "decision", "review",
        {
          "route" => route, "rationale" => "Independent review decision.",
          "evidence" => [ "Validation is current." ], "blocker_owner" => "review_gate",
          "head_revision" => fix_payload.fetch("head_revision"),
          "diff_digest" => fix_payload.fetch("diff_digest"),
          "fix_receipt_id" => "fix-1", "validation_receipt_id" => "validation-1"
        },
        "review-#{route}-1"
      )
      store.append!(decision)
      yield task, worktree_root, decision
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
