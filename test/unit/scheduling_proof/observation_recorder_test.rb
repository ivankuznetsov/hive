require "test_helper"
require "hive/scheduling_proof/observation_recorder"

class SchedulingProofObservationRecorderTest < Minitest::Test
  include HiveTestHelper

  def test_deduplicates_volatile_tick_changes_but_records_semantic_changes
    with_tmp_dir do |dir|
      recorder = Hive::SchedulingProof::ObservationRecorder.new
      first = observation(dir)
      assert recorder.record(first)
      refute recorder.record(first.merge("queue_position" => 9, "observed_at" => "2026-07-17T12:01:00Z"))
      assert recorder.record(first.merge("reason" => "dependency_wait",
                                         "dependency" => { "blocked_by" => "demo:other" }))

      lines = File.readlines(File.join(dir, "events.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal 2, lines.size
      assert_equal %w[global_capacity dependency_wait], lines.map { |line| line.fetch("reason") }
      assert lines.all? { |line| line.fetch("event_type") == "scheduling_observed" }

      projection = Hive::TaskProjection::Store.new(task_folder: dir).read.to_h
      assert_equal "dependency_wait", projection.dig("scheduling", "current", "reason")
      assert_equal "global_capacity", projection.dig("scheduling", "history", 0, "reason")
    end
  end

  def test_generation_change_is_semantic_and_supersedes_old_observation
    with_tmp_dir do |dir|
      recorder = Hive::SchedulingProof::ObservationRecorder.new
      recorder.record(observation(dir))
      recorder.record(observation(dir).merge("task_generation" => 4))

      projection = Hive::TaskProjection::Store.new(task_folder: dir).read.to_h
      assert_equal 4, projection.dig("scheduling", "current", "task_generation")
      assert_equal "older_task_generation",
                   projection.dig("scheduling", "history", 0, "superseded_reason")
    end
  end

  def test_semantic_signature_canonicalizes_nested_arrays
    recorder = Hive::SchedulingProof::ObservationRecorder.new
    left = observation("/tmp/task").merge(
      "provider" => [ { "model" => "gpt-5", "provider" => "codex" } ]
    )
    right = observation("/tmp/task").merge(
      "provider" => [ { "provider" => "codex", "model" => "gpt-5" } ]
    )

    assert_equal recorder.semantic_signature(left), recorder.semantic_signature(right)
  end

  private

  def observation(dir)
    {
      "project" => "demo", "task_id" => 42, "task_slug" => "task-260717-abcd",
      "task_folder" => dir, "workflow" => "coding", "stage" => "4-execute",
      "task_generation" => 3, "attempt_id" => nil, "reason" => "global_capacity",
      "observed_at" => "2026-07-17T12:00:00Z", "eligible" => true,
      "queue_position" => 1, "action" => {
        "kind" => "wait", "text" => "Wait", "command" => nil,
        "requires_confirmation" => false,
        "preconditions" => { "stage" => "4-execute", "task_generation" => 3, "attempt_id" => nil }
      }
    }
  end
end
