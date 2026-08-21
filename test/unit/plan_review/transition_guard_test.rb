require "test_helper"
require "hive/config"
require "hive/plan_review/transition_guard"

class PlanReviewTransitionGuardTest < Minitest::Test
  include HiveTestHelper

  Workflow = Struct.new(:id, keyword_init: true)
  Task = Struct.new(
    :folder, :project_root, :slug, :id, :workflow, :meta_yml_path,
    :stage_index, :stage_name,
    keyword_init: true
  )

  def test_prepare_and_locked_verify_allow_only_the_same_cleared_observation
    with_task do |task, cfg|
      projection = publish_projection(task, cfg, state: "cleared")
      observation = Hive::PlanReview::TransitionGuard.prepare!(
        task:, destination: "4-execute", config: cfg,
        orchestrator: ->(**) { projection }
      )

      assert Hive::PlanReview::TransitionGuard.verify!(
        task:, destination: "4-execute", observation:, config: cfg
      )

      newer = projection.record.to_h.merge(
        "version" => projection.record.version + 1,
        "updated_at" => "2026-08-12T12:01:00.000000Z"
      )
      Hive::PlanReview::Store.new(task_folder: task.folder).publish_current!(
        Hive::PlanReview::Record.new(newer), expected_version: projection.record.version
      )
      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.verify!(
          task:, destination: "4-execute", observation:, config: cfg
        )
      end
      assert_includes error.message, "changed before the transition"
    end
  end

  def test_force_equivalent_guard_rejects_missing_blocked_and_stale_reviews
    with_task do |task, cfg|
      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.prepare!(
          task:, destination: "4-execute", config: cfg,
          orchestrator: ->(**) { nil }
        )
      end
      assert_includes error.message, "has not produced a current resolution"
    end

    with_task do |task, cfg|
      projection = publish_projection(
        task, cfg, state: "blocked",
        blockers: [ { "owner" => "operator", "reason" => "coverage_failed" } ],
        required_action: "restore reviewer capability"
      )
      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.prepare!(
          task:, destination: "4-execute", config: cfg,
          orchestrator: ->(**) { projection }
        )
      end
      assert_equal "blocked", error.review_state
      assert_equal "restore reviewer capability", error.required_action
    end

    with_task do |task, cfg|
      projection = publish_projection(task, cfg, state: "cleared")
      File.write(File.join(task.folder, "plan.md"), "# externally edited\n")
      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.prepare!(
          task:, destination: "4-execute", config: cfg,
          orchestrator: ->(**) { projection }
        )
      end
      assert_includes error.message, "canonical plan changed"
    end
  end

  def test_verified_candidate_digest_is_current_but_policy_drift_is_not
    with_task do |task, cfg|
      original = File.binread(File.join(task.folder, "plan.md"))
      candidate = "# verified candidate\n"
      File.binwrite(File.join(task.folder, "plan.md"), candidate)
      projection = publish_projection(
        task, cfg, state: "degraded_cleared",
        plan_digest: Digest::SHA256.hexdigest(original),
        candidate_digest: Digest::SHA256.hexdigest(candidate)
      )

      observation = Hive::PlanReview::TransitionGuard.prepare!(
        task:, destination: "4-execute", config: cfg,
        orchestrator: ->(**) { projection }
      )
      assert_equal Digest::SHA256.hexdigest(candidate), observation.plan_digest

      File.binwrite(File.join(task.folder, "plan.md"), original)
      reverted = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.verify!(
          task:, destination: "4-execute", observation:, config: cfg
        )
      end
      assert_includes reverted.message, "canonical plan changed"
      File.binwrite(File.join(task.folder, "plan.md"), candidate)

      changed_cfg = Marshal.load(Marshal.dump(cfg))
      changed_cfg["plan_review"]["adapter"] = "replacement-review-adapter"
      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.verify!(
          task:, destination: "4-execute", observation:, config: changed_cfg
        )
      end
      assert_includes error.message, "policy changed"
    end
  end

  def test_non_coding_and_non_boundary_moves_are_not_applicable
    with_task(workflow_id: "custom") do |task, cfg|
      assert_nil Hive::PlanReview::TransitionGuard.prepare!(
        task:, destination: "4-execute", config: cfg,
        orchestrator: ->(**) { flunk "custom workflows must not initialize review" }
      )
    end
    with_task do |task, cfg|
      assert_nil Hive::PlanReview::TransitionGuard.prepare!(
        task:, destination: "2-brainstorm", config: cfg,
        orchestrator: ->(**) { flunk "backward moves must not initialize review" }
      )
    end
  end

  def test_execute_entry_validates_review_or_records_legacy_adoption
    with_task(stage_index: 4, stage_name: "execute") do |task, cfg|
      assert Hive::PlanReview::TransitionGuard.validate_execute_entry!(
        task:, config: cfg, clock: -> { Time.utc(2026, 8, 12, 12) }
      )
      receipt = JSON.parse(File.binread(
        File.join(task.folder, "plan-review", "legacy-execute-adoption.json")
      ))
      assert_equal "pre_feature_execute_task", receipt.fetch("reason")
      assert_equal "4-execute", receipt.fetch("stage")
      assert Hive::PlanReview::TransitionGuard.validate_execute_entry!(
        task:, config: cfg, clock: -> { Time.utc(2026, 8, 12, 13) }
      )
    end

    with_task(stage_index: 4, stage_name: "execute") do |task, cfg|
      FileUtils.mkdir_p(File.join(task.folder, "plan-review"))
      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.validate_execute_entry!(task:, config: cfg)
      end
      assert_includes error.message, "current projection is missing"
      refute File.exist?(
        File.join(task.folder, "plan-review", "legacy-execute-adoption.json")
      )
    end
  end

  def test_invalid_review_inputs_are_normalized_to_blocked_or_invalid_results
    with_task do |task, cfg|
      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.prepare!(
          task:, destination: "4-execute", config: cfg,
          orchestrator: ->(**) { raise Hive::ConfigError, "broken config" }
        )
      end
      assert_includes error.message, "unavailable or invalid"

      FileUtils.mkdir_p(File.join(task.folder, "plan-review"))
      File.write(File.join(task.folder, "plan-review", "current.json"), "not json")
      assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.prepare_existing!(
          task:, destination: "4-execute", config: cfg
        )
      end
      assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.verify!(
          task:, destination: "4-execute", observation: Object.new, config: cfg
        )
      end
    end

    with_task do |task, cfg|
      projection = publish_projection(task, cfg, state: "cleared")
      File.unlink(File.join(task.folder, "plan.md"))
      result = Hive::PlanReview::TransitionGuard.freshness(
        task:, projection:, config: cfg
      )
      assert_equal "invalid", result.fetch("status")
      assert_includes result.fetch("reason"), "unavailable"
    end
  end

  def test_policy_adoption_and_run_level_parse_failures_are_fail_closed
    with_task do |task, cfg|
      projection = publish_projection(task, cfg, state: "cleared")
      store = Hive::PlanReview::Store.new(task_folder: task.folder)
      bad_policy = store.write_review_artifact!(
        review_id: projection.record.review_id, basename: "bad-policy.json",
        content: "not json"
      )
      bad_record = Hive::PlanReview::Record.new(
        projection.record.to_h.merge(
          "artifacts" => projection.record["artifacts"].merge("policy" => bad_policy)
        )
      )
      refute Hive::PlanReview::TransitionGuard.send(
        :policy_configuration_matches?, bad_record, task, cfg
      )
    end

    with_task do |task, cfg|
      projection = publish_projection(task, cfg, state: "cleared")
      store = Hive::PlanReview::Store.new(task_folder: task.folder)
      File.write(File.join(store.root, "level.json"), "not json")
      assert Hive::PlanReview::TransitionGuard.send(
        :policy_configuration_matches?, projection.record, task, cfg
      )
    end

    with_task(stage_index: 4, stage_name: "execute") do |task, cfg|
      replacement = ->(*) { raise Errno::EACCES, "denied" }
      with_replaced_singleton_method(Hive::AtomicFile, :write, replacement) do
        error = assert_raises(Hive::PlanReview::TransitionBlocked) do
          Hive::PlanReview::TransitionGuard.validate_execute_entry!(task:, config: cfg)
        end
        assert_includes error.message, "adoption could not be recorded"
      end
    end

    with_task(stage_index: 4, stage_name: "execute") do |task, cfg|
      root = File.join(task.folder, "plan-review")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "legacy-execute-adoption.json"), "not json")
      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.validate_execute_entry!(task:, config: cfg)
      end
      assert_includes error.message, "invalid JSON"
    end
  end

  private

  def with_task(workflow_id: "coding", stage_index: 3, stage_name: "plan")
    Dir.mktmpdir("plan-review-transition") do |root|
      slug = "guard-test-260812-abcd"
      folder = File.join(
        root, ".hive-state", "stages", "#{stage_index}-#{stage_name}", slug
      )
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "plan.md"), "# reviewed plan\n")
      meta_path = File.join(folder, "meta.yml")
      File.write(meta_path, "id: 42\nworkflow: #{workflow_id}\n")
      task = Task.new(
        folder:, project_root: root, slug:, id: 42,
        workflow: Workflow.new(id: workflow_id), meta_yml_path: meta_path,
        stage_index:, stage_name:
      )
      cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
      yield task, cfg
    end
  end

  def publish_projection(task, cfg, state:, blockers: [], required_action: nil,
                         plan_digest: nil, candidate_digest: nil)
    store = Hive::PlanReview::Store.new(task_folder: task.folder)
    plan_digest ||= Digest::SHA256.file(File.join(task.folder, "plan.md")).hexdigest
    review_id = Hive::PlanReview::Identity.logical(
      task_id: task.id, plan_generation: "#{Hive::PlanReview::Identity.task_generation(task)}:#{plan_digest}",
      policy_fingerprint: "c" * 64
    )
    common = {
      "schema" => "hive-plan-review", "schema_version" => 1,
      "review_id" => review_id, "prior_review_id" => nil,
      "task_id" => task.id.to_s,
      "task_generation" => Hive::PlanReview::Identity.task_generation(task),
      "plan_digest" => plan_digest, "policy_fingerprint" => "c" * 64,
      "computed_level" => "standard", "effective_level" => "standard",
      "created_at" => "2026-08-12T12:00:00.000000Z"
    }
    store.create_review!(Hive::PlanReview::Record.new(common.merge("kind" => "manifest")))
    policy_ref = store.write_review_artifact!(
      review_id:, basename: "policy.json", json: true,
      content: {
        "configuration_fingerprint" => Hive::PlanReview::Policy.configuration_fingerprint(cfg)
      }
    )
    executable = %w[skipped cleared degraded_cleared].include?(state)
    outcome = executable ? state : (state == "blocked" ? "blocked" : nil)
    record = Hive::PlanReview::Record.new(common.merge(
      "kind" => "projection", "version" => 1,
      "candidate_plan_digest" => candidate_digest,
      "state" => state, "outcome" => outcome,
      "attempt_ids" => [], "current_attempt_id" => nil,
      "coverage" => [], "findings" => [], "decisions" => [], "routes" => [],
      "artifacts" => { "policy" => policy_ref }, "blockers" => blockers,
      "required_action" => required_action, "degradation_reason" => nil,
      "execution_allowed" => executable, "policy_reasons" => [],
      "level_sources" => {
        "computed" => "standard", "project" => "skip",
        "workflow" => "skip", "run" => nil
      },
      "retry_at" => nil, "updated_at" => "2026-08-12T12:00:00.000000Z"
    ))
    Hive::PlanReview::Projection.new(store.publish_current!(record, expected_version: nil))
  end
end
