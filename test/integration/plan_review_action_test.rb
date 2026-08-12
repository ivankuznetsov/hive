require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/plan_review"

class PlanReviewActionIntegrationTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(
    :folder, :project_root, :hive_state_path, :slug, :id, :stage_index, :stage_name,
    keyword_init: true
  )

  def test_public_command_emits_schema_valid_action_and_idempotent_replay
    with_current_review do |task, store, current|
      arguments = command_arguments(current)
      first = command(task, store, **arguments)
      out, = capture_io { first.call }
      payload = JSON.parse(out)

      assert schema.valid?(payload), schema.validate(payload).to_a.inspect
      assert payload.fetch("applied")
      assert_equal "approved", store.current["findings"].first.fetch("lifecycle")

      replay = command(task, store, **arguments)
      replay_out, = capture_io { replay.call }
      replay_payload = JSON.parse(replay_out)
      assert schema.valid?(replay_payload), schema.validate(replay_payload).to_a.inspect
      refute replay_payload.fetch("applied")
      assert replay_payload.fetch("noop")
      assert_equal 1, store.current["decisions"].length
    end
  end

  def test_stale_observation_emits_typed_error_without_mutation
    with_current_review do |task, store, current|
      cmd = command(
        task, store, **command_arguments(current).merge(
          expected_artifact_digest: "0" * 64
        )
      )
      out, _err, status = with_captured_exit { cmd.call }
      payload = JSON.parse(out)

      assert_equal Hive::ExitCodes::TEMPFAIL, status
      assert schema.valid?(payload), schema.validate(payload).to_a.inspect
      assert_equal "stale_decision", payload.fetch("error_kind")
      assert_empty store.current["decisions"]
    end
  end

  private

  def command(task, store, **arguments)
    Hive::Commands::PlanReview.new(
      task.folder, "approve-finding", **arguments, json: true,
      resolver: -> { task },
      service_factory: lambda do |resolved|
        Hive::PlanReview::DecisionService.new(
          task: resolved, clock: -> { Time.utc(2026, 8, 12, 12) },
          task_locker: ->(&block) { block.call },
          commit_locker: ->(&block) { block.call }, committer: ->(*) { }
        )
      end,
      resumer: ->(_resolved) { Hive::PlanReview::Projection.new(store.current) }
    )
  end

  def command_arguments(current)
    {
      review_id: current.review_id, task_generation: current.task_generation,
      policy_fingerprint: current.policy_fingerprint,
      expected_artifact_digest: Hive::PlanReview::Projection.new(current).observation_digest,
      target_fingerprint: current["findings"].first.fetch("fingerprint")
    }
  end

  def with_current_review
    Dir.mktmpdir("hive-plan-review-command") do |root|
      folder = File.join(root, "task")
      FileUtils.mkdir_p(folder)
      task = FakeTask.new(
        folder:, project_root: root, hive_state_path: File.join(root, ".hive-state"),
        slug: "demo-task", id: "task-1", stage_index: 3, stage_name: "plan"
      )
      store = Hive::PlanReview::Store.new(task_folder: folder)
      manifest = Hive::PlanReview::Record.new(
        "schema" => "hive-plan-review", "schema_version" => 1, "kind" => "manifest",
        "review_id" => "pr-#{'a' * 64}", "prior_review_id" => nil,
        "task_id" => "task-1", "task_generation" => "generation-1",
        "plan_digest" => "b" * 64, "policy_fingerprint" => "c" * 64,
        "computed_level" => "standard", "effective_level" => "standard",
        "created_at" => "2026-08-12T12:00:00Z"
      )
      store.create_review!(manifest)
      finding = Hive::PlanReview::Finding.new(
        "source" => "whole_document", "classification" => "gated_auto",
        "risk" => "medium", "title" => "Confirm compatibility",
        "description" => "The response contract needs approval.",
        "evidence" => {
          "path" => "plan.md", "start_line" => 3, "end_line" => 4,
          "anchor_digest" => "d" * 64
        },
        "lifecycle" => "open", "display_order" => 1
      )
      projection = Hive::PlanReview::Record.new(
        manifest.to_h.merge(
          "kind" => "projection", "version" => 1, "candidate_plan_digest" => nil,
          "state" => "awaiting_decision", "outcome" => nil,
          "attempt_ids" => [], "current_attempt_id" => nil, "coverage" => [],
          "findings" => [ finding.to_h ], "decisions" => [], "routes" => [],
          "artifacts" => {}, "blockers" => [], "required_action" => "approve finding",
          "degradation_reason" => nil, "execution_allowed" => false,
          "updated_at" => "2026-08-12T12:00:00Z"
        )
      )
      store.publish_current!(projection, expected_version: nil)
      yield task, store, store.current
    end
  end

  def schema
    @schema ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-plan-review-action")))
    )
  end
end
