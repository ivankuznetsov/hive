require "test_helper"
require "hive/conditions/transition_guard"

class ConditionsTransitionGuardTest < Minitest::Test
  include HiveTestHelper

  TaskDouble = Data.define(:folder, :state_file, :stage_index, :stage_name)

  def test_finalize_to_done_requires_archive_ready_even_with_force
    with_tmp_dir do |dir|
      state_file = File.join(dir, "pr.md")
      File.write(state_file, "---\npr_url: https://github.com/acme/demo/pull/12\n---\n")
      task = TaskDouble.new(folder: dir, state_file: state_file, stage_index: 8, stage_name: "finalize")

      error = assert_raises(Hive::WrongStage) do
        Hive::Conditions::TransitionGuard.validate!(task, force: true)
      end
      assert_includes error.message, "archive_ready"

      write_journal(dir, finalization_records)
      assert Hive::Conditions::TransitionGuard.validate!(task, force: false)
    end
  end

  private

  def write_journal(dir, records)
    File.write(File.join(dir, "events.jsonl"), records.map { |record| JSON.generate(record) }.join("\n") + "\n")
  end

  def finalization_records
    coordinates = {
      "job_id" => "job-1", "repository" => "github.com/acme/demo", "pr_number" => 12,
      "pr_url" => "https://github.com/acme/demo/pull/12", "head_sha" => "a" * 40,
      "head_generation" => 1, "finalize_attempt_id" => "attempt-1"
    }
    [
      record("finalized", "finalized", { "kind" => "finalize_attempt", "attempt_id" => "attempt-1" }, coordinates),
      record("merged", "merged", { "kind" => "babysitter_job", "job_id" => "job-1", "claim_fence" => 1 },
             coordinates.merge("merged_at" => "2026-07-17T13:00:00Z")),
      record("archive_ready", "archive", { "kind" => "reconciler", "name" => "hive-finalization-reconciler-v1" },
             coordinates.merge("terminal_event_id" => "merged"))
    ]
  end

  def record(type, id, producer, payload)
    Hive::TaskJournal::Envelope.authoritative({
      event_type: type, event_id: id, occurred_at: "2026-07-17T13:00:00.000000Z",
      observed_at: "2026-07-17T13:00:00.000000Z", task: { "id" => "42", "slug" => "task" },
      workflow: "coding", stage: "8-finalize", attempt_id: "attempt-1", task_generation: 3,
      ownership_generation: "owner-1", reason: type, evidence: [], provenance: { "source" => "test" },
      producer: producer, payload: payload
    })
  end
end
