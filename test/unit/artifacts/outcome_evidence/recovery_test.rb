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
      assert_equal 0, recovery.epoch(task_generation: "other-task-generation")

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

      stale_epoch = blocked_pointer(epoch: 0, generation: "1" * 64, digest: "2" * 64)
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        recovery.advance!(
          pointer: stale_epoch, task_generation: "task-generation-1",
          expected_generation: stale_epoch.fetch("generation"),
          expected_digest: stale_epoch.fetch("recovery_digest")
        )
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        recovery.advance!(
          pointer: blocked_pointer(epoch: "not-an-integer"),
          task_generation: "task-generation-1",
          expected_generation: "a" * 64, expected_digest: "f" * 64
        )
      end
    end
  end

  def test_corrupt_oversize_duplicate_and_symlinked_recovery_records_fail_closed
    with_tmp_dir do |dir|
      task = FakeTask.new(folder: dir, slug: "demo-task")
      recovery = Recovery.new(task: task, project: "demo", clock: -> { NOW })
      pointer = blocked_pointer(epoch: 0)
      recovery.advance!(
        pointer: pointer, task_generation: "task-generation-1",
        expected_generation: pointer.fetch("generation"),
        expected_digest: pointer.fetch("recovery_digest")
      )
      path = File.join(dir, "outcome-evidence", "recovery.json")
      valid = File.binread(path)
      invalid_documents = [
        "{",
        "{}",
        valid.sub('"schema":', '"schema":"duplicate","schema":'),
        "x" * (Recovery::MAX_BYTES + 1)
      ]
      invalid_documents.each do |source|
        File.binwrite(path, source)
        error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          recovery.epoch(task_generation: "task-generation-1")
        end
        assert_match(/recovery/, error.message)
        assert_equal source, File.binread(path)
      end

      FileUtils.rm_f(path)
      target = File.join(dir, "outside-recovery.json")
      File.binwrite(target, valid)
      File.symlink(target, path)
      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        recovery.epoch(task_generation: "task-generation-1")
      end
      assert_match(/symlink/, error.message)
      assert File.symlink?(path)
      assert_equal valid, File.binread(target)
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
