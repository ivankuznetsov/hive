require "test_helper"
require "hive/artifacts/outcome_evidence/recovery"

class OutcomeEvidenceRecoveryTest < Minitest::Test
  include HiveTestHelper
  Recovery = Hive::Artifacts::OutcomeEvidence::Recovery
  FakeTask = Data.define(:folder, :slug)
  NOW = Time.utc(2026, 8, 13, 23, 15, 0)

  def test_guarded_advance_is_idempotent_and_rejects_stale_generation_or_digest
    with_tmp_dir do |dir|
      task = FakeTask.new(folder: dir, slug: "demo-task")
      recovery = Recovery.new(task: task, project: "demo", clock: -> { NOW })
      pointer = blocked_pointer(epoch: 0)

      assert_equal 0, recovery.epoch(task_generation: "task-generation-1")
      first = recovery.advance!(
        pointer: pointer, task_generation: "task-generation-1",
        expected_generation: pointer.fetch("generation"),
        expected_digest: pointer.fetch("recovery_digest")
      )
      assert_equal 1, first.fetch("epoch")
      assert_equal first, recovery.advance!(
        pointer: pointer, task_generation: "task-generation-1",
        expected_generation: pointer.fetch("generation"),
        expected_digest: pointer.fetch("recovery_digest")
      )
      assert_equal 1, recovery.epoch(task_generation: "task-generation-1")

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        recovery.advance!(
          pointer: pointer, task_generation: "task-generation-1",
          expected_generation: "b" * 64,
          expected_digest: pointer.fetch("recovery_digest")
        )
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        recovery.advance!(
          pointer: pointer, task_generation: "task-generation-1",
          expected_generation: pointer.fetch("generation"),
          expected_digest: "c" * 64
        )
      end

      second_pointer = blocked_pointer(epoch: 1, generation: "d" * 64, digest: "e" * 64)
      second = recovery.advance!(
        pointer: second_pointer, task_generation: "task-generation-1",
        expected_generation: second_pointer.fetch("generation"),
        expected_digest: second_pointer.fetch("recovery_digest")
      )
      assert_equal 2, second.fetch("epoch")
      assert_equal "a" * 64, first.fetch("blocked_generation")
      assert_equal "d" * 64, second.fetch("blocked_generation")
    end
  end

  private

  def blocked_pointer(epoch:, generation: "a" * 64, digest: "f" * 64)
    {
      "status" => "blocked", "generation" => generation,
      "recovery_epoch" => epoch, "recovery_digest" => digest
    }
  end
end
