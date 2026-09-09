require "test_helper"
require "tmpdir"
require "hive/markers"
require "hive/daemon/plan_approval"
require "hive/plan_review/policy"
require "hive/plan_review/store"
require "hive/task_meta"

# Unit coverage for the shared helper that the dispatcher's
# plan-approval auto-dispatch path relies on. The dispatcher tests
# exercise the end-to-end flow; these tests pin each branch of
# PlanApproval#prepare individually so a refactor that breaks one
# arm surfaces in this file rather than in a noisier integration
# failure.
class HiveDaemonPlanApprovalTest < Minitest::Test
  include HiveTestHelper

  PA = Hive::Daemon::PlanApproval

  def with_state_file(marker_line)
    Dir.mktmpdir("plan-approval-test") do |dir|
      path = File.join(dir, "plan.md")
      File.write(path, "# plan\n\n#{marker_line}\n")
      yield path
    end
  end

  # ---- rewrite_to_develop ----

  def test_rewrite_to_develop_swaps_verb
    assert_equal "hive develop slug --from 3-plan",
                 PA.rewrite_to_develop("hive plan slug --from 3-plan")
  end

  def test_rewrite_to_develop_preserves_quoting_on_complex_slugs
    # Shellwords round-trips quoted args safely so a slug with
    # special characters (unlikely but possible per the slug
    # regex) doesn't get mangled.
    cmd = "hive plan slug-with-dash --from 3-plan --project demo"
    assert_equal "hive develop slug-with-dash --from 3-plan --project demo",
                 PA.rewrite_to_develop(cmd)
  end

  def test_rewrite_to_develop_rejects_non_plan_verb
    err = assert_raises(ArgumentError) do
      PA.rewrite_to_develop("hive review slug --from 3-plan")
    end
    assert_match(/expects `hive plan/, err.message)
  end

  def test_rewrite_to_develop_accepts_already_develop_shaped_command
    # Idempotent for the bot's stale-Approve race: a row that already advanced
    # to :complete carries `hive develop ...` (ready_to_develop), and the tap
    # must dispatch it rather than crash on the non-plan verb.
    assert_equal "hive develop slug --from 3-plan",
                 PA.rewrite_to_develop("hive develop slug --from 3-plan")
  end

  def test_rewrite_to_develop_rejects_empty_command
    assert_raises(ArgumentError) { PA.rewrite_to_develop("") }
    assert_raises(ArgumentError) { PA.rewrite_to_develop(nil) }
  end

  def test_rewrite_to_develop_rejects_command_with_only_two_argv_elements
    # `hive plan` alone (no slug) is malformed for our purposes.
    assert_raises(ArgumentError) { PA.rewrite_to_develop("hive plan") }
  end

  # ---- prepare (full flow) ----

  def test_prepare_flips_waiting_marker_to_complete_and_returns_develop_command
    with_state_file("<!-- WAITING -->") do |path|
      cmd = PA.prepare(
        "hive plan slug --from 3-plan", path, clearance_checker: -> { true }
      )
      assert_equal "hive develop slug --from 3-plan", cmd
      assert_equal :complete, Hive::Markers.current(path).name
    end
  end

  def test_prepare_leaves_complete_marker_alone_and_still_returns_develop_command
    # Idempotent for the race where a manual operator action (or a
    # prior tick) already flipped the marker between the status read
    # and dispatch. The dispatch is still valid; we just don't
    # re-flip.
    with_state_file("<!-- COMPLETE -->") do |path|
      cmd = PA.prepare(
        "hive plan slug --from 3-plan", path, clearance_checker: -> { true }
      )
      assert_equal "hive develop slug --from 3-plan", cmd
      assert_equal :complete, Hive::Markers.current(path).name
    end
  end

  def test_prepare_dispatches_develop_for_already_advanced_complete_row
    # The bot's stale-Approve race made concrete: the row is already :complete
    # and its suggested_command is already `hive develop ...`. prepare must
    # return that develop command (no-op on the marker), making the :complete
    # branch reachable instead of raising on the develop verb.
    with_state_file("<!-- COMPLETE -->") do |path|
      cmd = PA.prepare(
        "hive develop slug --from 3-plan --project hive", path,
        clearance_checker: -> { true }
      )
      assert_equal "hive develop slug --from 3-plan --project hive", cmd
      assert_equal :complete, Hive::Markers.current(path).name
    end
  end

  def test_prepare_raises_not_approvable_for_error_marker
    with_state_file("<!-- ERROR reason=plan_failed -->") do |path|
      err = assert_raises(PA::NotApprovable) do
        PA.prepare(
          "hive plan slug --from 3-plan", path, clearance_checker: -> { true }
        )
      end
      assert_match(/marker=:error/, err.message)
      # Marker NOT touched.
      assert_equal :error, Hive::Markers.current(path).name
    end
  end

  def test_prepare_raises_not_approvable_for_agent_working_marker
    with_state_file("<!-- AGENT_WORKING pid=12345 -->") do |path|
      assert_raises(PA::NotApprovable) do
        PA.prepare(
          "hive plan slug --from 3-plan", path, clearance_checker: -> { true }
        )
      end
    end
  end

  def test_prepare_validates_command_BEFORE_flipping_marker
    # Load-bearing: if the suggested_command is malformed and we
    # flipped the marker first, the row would land at :complete
    # with no follow-up dispatch — worse than the original failure
    # because the operator sees an "approved" plan that never
    # advances. Validate command FIRST so the failure path leaves
    # the marker untouched at :waiting for inspection.
    with_state_file("<!-- WAITING -->") do |path|
      assert_raises(ArgumentError) do
        PA.prepare("hive review slug --from 3-plan", path)
      end
      assert_equal :waiting, Hive::Markers.current(path).name,
                   "command validation must happen before marker flip"
    end
  end

  def test_prepare_checks_clearance_before_flipping_marker
    with_state_file("<!-- WAITING -->") do |path|
      error = assert_raises(PA::NotApprovable) do
        PA.prepare(
          "hive plan slug --from 3-plan", path, clearance_checker: -> { false }
        )
      end

      assert_includes error.message, "has not authorized execution"
      assert_equal :waiting, Hive::Markers.current(path).name
    end
  end

  def test_prepare_production_path_uses_current_clearance_without_launching_review
    with_reviewed_task("cleared", task_id: 42) do |task, cfg|
      command = PA.prepare("hive plan #{task.slug} --from 3-plan", task.state_file)

      assert_equal "hive develop #{task.slug} --from 3-plan", command
      assert_equal :complete, Hive::Markers.current(task.state_file).name
      assert_equal "cleared", Hive::PlanReview::Store.new(task_folder: task.folder).current.state
    end

    with_reviewed_task("blocked", task_id: 43) do |task, _cfg|
      error = assert_raises(PA::NotApprovable) do
        PA.prepare("hive plan #{task.slug} --from 3-plan", task.state_file)
      end
      assert_includes error.message, "does not authorize execution"
      assert_equal :waiting, Hive::Markers.current(task.state_file).name
    end
  end

  def with_reviewed_task(state, task_id:)
    Dir.mktmpdir("plan-approval-production") do |root|
      folder = File.join(root, ".hive-state", "stages", "3-plan", "reviewed-task")
      FileUtils.mkdir_p(folder)
      Hive::TaskMeta.write(
        folder, id: task_id, slug: "reviewed-task", display_name: nil,
        workflow: "coding", plan_review_required: true
      )
      prepare_test_runtime_project(root)
      File.write(File.join(folder, "plan.md"), "# reviewed plan\n<!-- WAITING -->\n")
      task = Hive::Task.new(folder)
      cfg = Hive::Config.load(root)
      publish_clearance(task, cfg, state)
      yield task, cfg
    end
  end

  def publish_clearance(task, cfg, state)
    store = Hive::PlanReview::Store.new(task_folder: task.folder)
    plan_digest = Digest::SHA256.file(task.state_file).hexdigest
    generation = Hive::PlanReview::Identity.task_generation(task)
    review_id = Hive::PlanReview::Identity.logical(
      task_id: task.id, plan_generation: "#{generation}:#{plan_digest}",
      policy_fingerprint: "c" * 64
    )
    common = {
      "schema" => "hive-plan-review", "schema_version" => 1,
      "review_id" => review_id, "prior_review_id" => nil,
      "task_id" => task.id.to_s, "task_generation" => generation,
      "plan_digest" => plan_digest, "policy_fingerprint" => "c" * 64,
      "computed_level" => "standard", "effective_level" => "standard",
      "created_at" => "2026-08-12T12:00:00Z"
    }
    store.create_review!(Hive::PlanReview::Record.new(common.merge("kind" => "manifest")))
    policy = store.write_review_artifact!(
      review_id:, basename: "policy.json", json: true,
      content: {
        "configuration_fingerprint" => Hive::PlanReview::Policy.configuration_fingerprint(cfg)
      }
    )
    executable = state == "cleared"
    store.publish_current!(Hive::PlanReview::Record.new(common.merge(
      "kind" => "projection", "version" => 1, "candidate_plan_digest" => nil,
      "state" => state, "outcome" => state, "attempt_ids" => [],
      "current_attempt_id" => nil, "coverage" => [], "findings" => [],
      "decisions" => [], "routes" => [], "artifacts" => { "policy" => policy },
      "blockers" => executable ? [] : [ { "owner" => "hive", "reason" => "blocked" } ],
      "required_action" => executable ? nil : "repair review",
      "degradation_reason" => nil, "execution_allowed" => executable,
      "policy_reasons" => [],
      "level_sources" => { "computed" => "standard", "project" => "skip", "workflow" => "skip", "run" => nil },
      "retry_at" => nil, "updated_at" => "2026-08-12T12:00:00Z"
    )), expected_version: nil)
  end
end
