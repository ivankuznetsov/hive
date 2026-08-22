require_relative "fix_test"
require "hive/stages/patrol_fix/validate"

class PatrolFixValidateStageTest < Minitest::Test
  def test_failed_deliberate_validation_is_durable_and_never_executes_reproduction_prose
    PatrolFixStageFixture.with_task(stage: "3-validate") do |task, root, manifest|
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
      store.append!(PatrolFixStageFixture.decision_receipt(manifest, "fix"))
      worktrees = File.join(root, "worktrees")
      custody = Hive::PatrolFix::WorktreeReceipt.new(task_folder: task.folder, project_root: task.project_root, slug: task.slug, worktree_root: worktrees)
      owner = custody.prepare!(generation: 1, evidence_digest: "a" * 64, base_revision: manifest.fetch("target_revision"))
      File.write(File.join(owner.fetch("worktree"), "app.rb"), "puts :fixed\n")
      PatrolFixStageFixture.git(owner.fetch("worktree"), "add", "app.rb")
      PatrolFixStageFixture.git(owner.fetch("worktree"), "commit", "-m", "Fix")
      payload = custody.capture!(generation: 1, evidence_digest: "a" * 64).merge("validation_commands" => [])
      store.append!({ "schema" => "hive-patrol-fix-receipt", "schema_version" => 1, "receipt_id" => "fix-1", "kind" => "fix", "stage" => "fix",
        "task" => manifest.fetch("task"), "evidence_revision" => manifest.fetch("evidence_revision"), "recorded_at" => "2026-08-20T12:01:00Z", "payload" => payload })
      cfg = { "patrol" => { "commands" => { "test" => "ruby -e 'exit 7'" } } }

      result = Hive::Stages::PatrolFix::Validate.run!(task, cfg, worktree_root: worktrees)
      assert_equal :complete, result.fetch(:status)
      assert_equal "failed", result.dig(:receipt, "payload", "verdict")
      assert_equal [ "ordinary:test" ], result.dig(:receipt, "payload", "commands").map { |row| row.fetch("identity") }
      refute File.exist?("/tmp/never-from-prose")
    ensure
      File.delete("/tmp/never-from-prose") if File.exist?("/tmp/never-from-prose")
    end
  end
end
