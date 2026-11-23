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

  def test_pending_candidate_keeps_original_fresh_without_authorizing_execution
    with_task do |task, cfg|
      plan_path = File.join(task.folder, "plan.md")
      original = File.binread(plan_path)
      candidate = "# pending candidate\n"
      projection = publish_projection(
        task, cfg, state: "awaiting_decision",
        plan_digest: Digest::SHA256.hexdigest(original),
        candidate_digest: Digest::SHA256.hexdigest(candidate)
      )

      # Original bytes remain canonical until clearance; candidate bytes may be
      # present after a crash between promotion and terminal record publication.
      [ original, candidate ].each do |bytes|
        File.binwrite(plan_path, bytes)
        assert_equal "current", Hive::PlanReview::TransitionGuard.freshness(
          task:, projection:, config: cfg
        ).fetch("status")
        assert_raises(Hive::PlanReview::TransitionBlocked) do
          Hive::PlanReview::TransitionGuard.prepare!(
            task:, destination: "4-execute", config: cfg,
            orchestrator: ->(**) { projection }
          )
        end
      end

      File.binwrite(plan_path, "# unrelated edit\n")
      assert_equal "stale", Hive::PlanReview::TransitionGuard.freshness(
        task:, projection:, config: cfg
      ).fetch("status")
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

  # todero (2026-11-20): providers ran out of quota and the operator rerouted
  # the plan-review reviewers. Tasks whose reviews had already cleared were
  # refused at execute entry ("plan review policy changed after resolution"),
  # and reverting the reroute would have refused the next batch. A finished
  # verdict does not depend on who would review next.
  def test_resolved_review_stays_current_across_a_reviewer_reroute_and_its_revert
    %w[skipped cleared degraded_cleared].each do |state|
      with_task(stage_index: 4, stage_name: "execute") do |task, cfg|
        projection = publish_projection(task, cfg, state:, policy_format: :current)
        rerouted = reroute(routed_as_cleared(cfg))

        assert_equal "current", freshness_status(task, projection, rerouted), state
        assert Hive::PlanReview::TransitionGuard.validate_execute_entry!(task:, config: rerouted)
      end
    end

    with_task do |task, cfg|
      projection = publish_projection(task, cfg, state: "cleared", policy_format: :current)
      rerouted = reroute(cfg)
      observation = Hive::PlanReview::TransitionGuard.prepare!(
        task:, destination: "4-execute", config: rerouted,
        orchestrator: ->(**) { projection }
      )
      assert Hive::PlanReview::TransitionGuard.verify!(
        task:, destination: "4-execute", observation:, config: rerouted
      )
    end

    # Cleared under the temporary routes, then the operator reverts them.
    with_task(stage_index: 4, stage_name: "execute") do |task, cfg|
      temporary = reroute(cfg)
      projection = publish_projection(task, temporary, state: "cleared", policy_format: :current)

      assert_equal "current", freshness_status(task, projection, cfg)
      assert Hive::PlanReview::TransitionGuard.validate_execute_entry!(task:, config: cfg)
    end
  end

  def test_verdict_relevant_policy_change_still_stales_a_resolved_review
    changes = {
      "minimum_level" => ->(cfg) { cfg["plan_review"]["minimum_level"] = "mandatory" },
      "coding minimum_level" => ->(cfg) { cfg["plan_review"]["coding"]["minimum_level"] = "mandatory" },
      "protected_paths" => ->(cfg) { cfg["plan_review"]["protected_paths"] += [ "app/**" ] },
      "coverage" => ->(cfg) { cfg["plan_review"]["coverage"]["optional"] = [ "security" ] },
      "classifier_version" => ->(cfg) { cfg["plan_review"]["classifier_version"] += 1 }
    }
    changes.each do |label, change|
      with_task(stage_index: 4, stage_name: "execute") do |task, cfg|
        publish_projection(task, cfg, state: "cleared", policy_format: :current)
        changed = reroute(cfg)
        change.call(changed)

        error = assert_raises(Hive::PlanReview::TransitionBlocked, label) do
          Hive::PlanReview::TransitionGuard.validate_execute_entry!(task:, config: changed)
        end
        assert_equal "plan review policy changed after resolution", error.blocked_reason, label
      end
    end
  end

  # Routes stay in the comparison while a review is unresolved: a review
  # blocked because a reviewer could not be launched (`unsupported`) must
  # restart once the route is fixed, rather than replay the stale block.
  def test_unresolved_or_blocked_review_goes_stale_on_a_reviewer_reroute
    with_task do |task, cfg|
      blocked = publish_projection(
        task, cfg, state: "blocked", policy_format: :current,
        blockers: [ { "owner" => "operator", "reason" => "coverage_unsupported" } ],
        required_action: "waive named coverage or restore required reviewer capability"
      )

      assert_equal "current", freshness_status(task, blocked, cfg)
      fixed = Hive::PlanReview::TransitionGuard.freshness(task:, projection: blocked, config: reroute(cfg))
      assert_equal [ "stale", "plan review policy changed after resolution" ],
                   fixed.values_at("status", "reason")
    end

    with_task do |task, cfg|
      reviewing = publish_projection(task, cfg, state: "reviewing", policy_format: :current)

      assert_equal "stale", freshness_status(task, reviewing, reroute(cfg))
    end
  end

  # Mirrors the two todero tasks (agent-and-app-api-v1-261105-7d3c,
  # shared-wishlists-with-gift-reservations-261105-d8c8): a cleared review
  # recorded by an older Hive (combined policy fingerprint only), already at
  # 4-execute, and its route receipts. Upgrading Hive must let the execute
  # retry pass while the reroute is still in place, without making the legacy
  # record any less sensitive to verdict-relevant drift.
  def test_legacy_cleared_review_passes_the_execute_retry_after_a_reviewer_reroute
    with_task(stage_index: 4, stage_name: "execute") do |task, cfg|
      as_cleared = routed_as_cleared(cfg)
      projection = publish_projection(
        task, as_cleared, state: "cleared", routes: route_receipts(as_cleared)
      )
      rerouted = reroute(as_cleared)

      assert_equal "current", freshness_status(task, projection, as_cleared),
                   "upgrading Hive alone must not stale a legacy review"
      refute_equal Hive::PlanReview::Policy.configuration_fingerprint(as_cleared),
                   Hive::PlanReview::Policy.configuration_fingerprint(rerouted)
      assert_equal "current", freshness_status(task, projection, rerouted)
      assert Hive::PlanReview::TransitionGuard.validate_execute_entry!(task:, config: rerouted)

      raised = Marshal.load(Marshal.dump(rerouted))
      raised["plan_review"]["protected_paths"] += [ "app/**" ]
      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.validate_execute_entry!(task:, config: raised)
      end
      assert_equal "plan review policy changed after resolution", error.blocked_reason
    end

    # Without receipts for the rerouted roles the route-only drift cannot be
    # proven, so the legacy record keeps the old fail-closed behavior.
    with_task(stage_index: 4, stage_name: "execute") do |task, cfg|
      as_cleared = routed_as_cleared(cfg)
      publish_projection(task, as_cleared, state: "cleared")

      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.validate_execute_entry!(task:, config: reroute(as_cleared))
      end
      assert_equal "plan review policy changed after resolution", error.blocked_reason
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

  def test_explicitly_disabled_review_does_not_gate_plan_or_execute
    with_task do |task, cfg|
      cfg["plan_review"]["enabled"] = false

      assert_nil Hive::PlanReview::TransitionGuard.prepare!(
        task:, destination: "4-execute", config: cfg,
        orchestrator: ->(**) { flunk "disabled review must not initialize" }
      )
      assert_nil Hive::PlanReview::TransitionGuard.prepare_existing!(
        task:, destination: "4-execute", config: cfg
      )
      assert Hive::PlanReview::TransitionGuard.verify!(
        task:, destination: "4-execute", observation: nil, config: cfg
      )
    end

    with_task(stage_index: 4, stage_name: "execute") do |task, cfg|
      cfg["plan_review"]["enabled"] = false

      assert Hive::PlanReview::TransitionGuard.validate_execute_entry!(
        task:, config: cfg
      )
      refute File.exist?(File.join(task.folder, "plan-review"))
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

  def test_reviewed_implementation_rework_keeps_clearance_across_policy_drift
    with_task(stage_index: 4, stage_name: "execute") do |task, cfg|
      publish_projection(task, cfg, state: "cleared")
      changed_cfg = Marshal.load(Marshal.dump(cfg))
      changed_cfg["plan_review"]["adapter"] = "replacement-review-adapter"

      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.validate_execute_entry!(
          task:, config: changed_cfg
        )
      end
      assert_includes error.message, "policy changed"

      assert Hive::PlanReview::TransitionGuard.validate_execute_entry!(
        task:, config: changed_cfg, reviewed_rework: true
      )

      task.id = 43
      changed_generation = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.validate_execute_entry!(
          task:, config: changed_cfg, reviewed_rework: true
        )
      end
      assert_includes changed_generation.message, "task generation changed"
      task.id = 42

      File.write(File.join(task.folder, "plan.md"), "# changed after review\n")
      changed_plan = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.validate_execute_entry!(
          task:, config: changed_cfg, reviewed_rework: true
        )
      end
      assert_includes changed_plan.message, "canonical plan changed"
    end
  end

  # hivedev f4 (2026-11-10): a backward move 6-review -> 4-execute after an
  # operator plan edit landed on a review execute entry would refuse.
  def test_execute_reentry_refuses_a_changed_plan_with_the_concrete_remedy
    with_task(stage_index: 6, stage_name: "review") do |task, cfg|
      publish_projection(task, cfg, state: "cleared")
      assert Hive::PlanReview::TransitionGuard.validate_execute_reentry!(
        task:, destination: "4-execute", config: cfg
      )

      File.write(File.join(task.folder, "plan.md"), "# reviewed plan\n\nOperator decision: keep the API.\n")
      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.validate_execute_reentry!(
          task:, destination: "4-execute", config: cfg
        )
      end

      assert_equal "canonical plan changed after plan review", error.blocked_reason
      assert_equal [ "6-review", "4-execute" ], [ error.current_stage, error.target_stage ]
      assert_equal "cleared", error.review_state
      assert error.required_action.start_with?(
        "Move the task back to 3-plan (`hive approve #{task.slug} --to 3-plan --from 6-review`)"
      )
      assert_includes error.required_action, "restore the reviewed plan.md and retry"
      assert_equal "canonical plan changed after plan review; required action: #{error.required_action}",
                   error.message
      refute File.exist?(File.join(task.folder, "plan-review", "legacy-execute-adoption.json"))
    end
  end

  # Outcome-evidence rework re-enters execute after reviewer routing may have
  # changed; execute entry tolerates that drift for a validated rework, so the
  # preflight must not refuse it first.
  def test_execute_reentry_tolerates_policy_drift_and_ignores_other_moves
    with_task(stage_index: 7, stage_name: "artifacts") do |task, cfg|
      publish_projection(task, cfg, state: "cleared")
      drifted = Marshal.load(Marshal.dump(cfg))
      drifted["plan_review"]["adapter"] = "replacement-review-adapter"

      assert Hive::PlanReview::TransitionGuard.validate_execute_reentry!(
        task:, destination: "4-execute", config: drifted
      )

      File.write(File.join(task.folder, "plan.md"), "# changed\n")
      assert Hive::PlanReview::TransitionGuard.validate_execute_reentry!(
        task:, destination: "3-plan", config: cfg
      )
      disabled = Marshal.load(Marshal.dump(cfg))
      disabled["plan_review"]["enabled"] = false
      assert Hive::PlanReview::TransitionGuard.validate_execute_reentry!(
        task:, destination: "4-execute", config: disabled
      )
    end

    with_task(stage_index: 4, stage_name: "execute") do |task, cfg|
      assert Hive::PlanReview::TransitionGuard.validate_execute_reentry!(
        task:, destination: "4-execute", config: cfg
      )
    end

    with_task(workflow_id: "research", stage_index: 6, stage_name: "review") do |task, cfg|
      assert Hive::PlanReview::TransitionGuard.validate_execute_reentry!(
        task:, destination: "4-execute", config: cfg
      )
    end
  end

  def test_execute_reentry_without_review_root_is_read_only
    with_task(stage_index: 6, stage_name: "review") do |task, cfg|
      assert Hive::PlanReview::TransitionGuard.validate_execute_reentry!(
        task:, destination: "4-execute", config: cfg
      )
      refute File.exist?(File.join(task.folder, "plan-review")),
             "the preflight must not record legacy adoption; execute entry owns that"

      File.write(task.meta_yml_path, "id: 42\nworkflow: coding\nplan_review_required: true\n")
      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.validate_execute_reentry!(
          task:, destination: "4-execute", config: cfg
        )
      end
      assert_includes error.message, "required plan review evidence is missing; required action: Move the task back"
    end

    with_task(stage_index: 6, stage_name: "review") do |task, cfg|
      at_execute = task.dup
      at_execute.stage_index = 4
      at_execute.stage_name = "execute"
      assert Hive::PlanReview::TransitionGuard.validate_execute_entry!(task: at_execute, config: cfg)

      assert Hive::PlanReview::TransitionGuard.validate_execute_reentry!(
        task:, destination: "4-execute", config: cfg
      )
    end

    with_task(stage_index: 6, stage_name: "review") do |task, cfg|
      FileUtils.mkdir_p(File.join(task.folder, "plan-review"))
      error = assert_raises(Hive::PlanReview::TransitionBlocked) do
        Hive::PlanReview::TransitionGuard.validate_execute_reentry!(
          task:, destination: "4-execute", config: cfg
        )
      end
      assert_includes error.message, "execute re-entry has invalid plan review evidence"
      assert_includes error.required_action, "hive approve #{task.slug} --to 3-plan --from 6-review"
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

  def freshness_status(task, projection, cfg)
    Hive::PlanReview::TransitionGuard.freshness(task:, projection:, config: cfg).fetch("status")
  end

  def route_row(agent, model, family, effort:, route:)
    { "agent" => agent, "model" => model, "family" => family, "effort" => effort, "route" => route }
  end

  # todero's routes when its reviews cleared (2026-11-19): Muse reviewers and
  # a Claude adversary standing in for Codex.
  def routed_as_cleared(cfg)
    cleared = Marshal.load(Marshal.dump(cfg))
    muse = route_row("muse", "muse-wonder-full-1.0", "meta", effort: "xhigh", route: "native_muse")
    cleared["plan_review"]["routes"].merge!(
      "primary" => muse, "verification" => muse,
      "adversarial" => route_row("claude", "claude-opus-5-5", "anthropic", effort: "xhigh", route: "native_claude")
    )
    cleared
  end

  # The 2026-11-20 reroute: Muse out of quota, Grok stands in.
  def reroute(cfg)
    rerouted = Marshal.load(Marshal.dump(cfg))
    grok = route_row("grok", "grok-4.7", "grok", effort: "xhigh", route: "native_grok_build")
    rerouted["plan_review"]["routes"].merge!("primary" => grok, "verification" => grok)
    rerouted
  end

  # Route receipts shaped like the ones a cleared review writes: the planner,
  # each reviewer leg (requested = the configured row, `agent` as
  # `provider`) and the planner revision.
  def route_receipts(cfg)
    planner = {
      "provider" => "muse", "model" => "muse-wonder-full-1.0", "family" => "meta",
      "effort" => "xhigh", "route" => "muse-code/v1"
    }
    reviewers = %w[primary adversarial verification].to_h do |role|
      row = cfg.dig("plan_review", "routes", role)
      requested = {
        "provider" => row.fetch("agent"), "model" => row.fetch("model"), "family" => row.fetch("family"),
        "effort" => row.fetch("effort"), "route" => row.fetch("route")
      }
      [ role, {
        "role" => role, "requested" => requested, "actual" => requested,
        "attempt_id" => "pra-#{Digest::SHA256.hexdigest(role)}", "capability_result" => "present",
        "independence_verified" => role == "adversarial", "outcome" => "success"
      } ]
    end
    [
      { "role" => "planner", "requested" => planner, "actual" => planner, "capability_result" => "captured" },
      reviewers.fetch("primary"), reviewers.fetch("adversarial"),
      { "role" => "planner_revision", "requested" => planner, "actual" => planner, "outcome" => "success" },
      reviewers.fetch("verification")
    ]
  end

  # `policy_format: :legacy` writes the policy artifact older Hive builds
  # wrote: the combined configuration fingerprint only.
  def publish_projection(task, cfg, state:, blockers: [], required_action: nil,
                         plan_digest: nil, candidate_digest: nil, routes: [],
                         policy_format: :legacy)
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
    policy_content = {
      "configuration_fingerprint" => Hive::PlanReview::Policy.configuration_fingerprint(cfg)
    }
    unless policy_format == :legacy
      policy_content["reviewer_routing"] = Hive::PlanReview::Policy.reviewer_routing(cfg)
    end
    policy_ref = store.write_review_artifact!(
      review_id:, basename: "policy.json", json: true, content: policy_content
    )
    executable = %w[skipped cleared degraded_cleared].include?(state)
    outcome = executable ? state : (state == "blocked" ? "blocked" : nil)
    record = Hive::PlanReview::Record.new(common.merge(
      "kind" => "projection", "version" => 1,
      "candidate_plan_digest" => candidate_digest,
      "state" => state, "outcome" => outcome,
      "attempt_ids" => [], "current_attempt_id" => nil,
      "coverage" => [], "findings" => [], "decisions" => [], "routes" => routes,
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
