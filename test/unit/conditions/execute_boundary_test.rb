require "test_helper"
require "hive/conditions/execute_boundary"
require "hive/conditions/transition_guard"
require "hive/attempts/generation"
require "hive/attempts/store"
require "hive/workflows/coding"

class ConditionsExecuteBoundaryTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(
    :folder, :state_file, :slug, :id, :worktree_path, :workflow,
    :stage_index, :stage_name, :project_root,
    keyword_init: true
  )

  class UnavailableGit
    def head_sha = raise(Hive::GitError, "head unavailable")
    def current_branch = raise(Errno::EACCES, "branch unavailable")
  end

  def test_mode_matrix_uses_marker_shadow_or_condition_authority_and_rollback_preserves_history
    with_fixture do |task, store, attempt, context, baseline|
      marker = evaluate(task, store, attempt, context, baseline, mode: "markers",
                        legacy_marker: :execute_complete)
      assert_equal :execute_complete, marker.marker_name
      assert_equal "markers", marker.selection.effective

      shadow_err = capture_io do
        shadow = evaluate(task, store, attempt, context, baseline, mode: "shadow",
                          legacy_marker: :execute_complete)
        assert_equal :execute_complete, shadow.marker_name
        assert_equal "shadow", shadow.selection.effective
      end.last
      assert_includes shadow_err, "shadow mismatch"
      records = Hive::TaskProjection.read_journal(File.join(task.folder, "events.jsonl"))
      assert_equal 1, records.count { |record| record["event_type"] == "shadow_audit" }

      conditioned = evaluate(task, store, attempt, context, baseline, mode: "conditions",
                             legacy_marker: :execute_complete)
      assert_equal :execute_waiting, conditioned.marker_name
      assert_equal "no_worktree_changes", conditioned.marker_attrs.fetch(:reason)

      count = records.size
      rolled_back = evaluate(task, store, attempt, context, baseline, mode: "markers",
                             legacy_marker: :execute_complete)
      assert_equal :execute_complete, rolled_back.marker_name
      assert_operator Hive::TaskProjection.read_journal(File.join(task.folder, "events.jsonl")).size,
                      :>=, count
    end
  end

  def test_attempt_b_new_head_satisfies_gate_and_supersedes_attempt_a_wait
    with_fixture do |task, store, attempt_a, context_a, baseline|
      first = evaluate(task, store, attempt_a, context_a, baseline, mode: "conditions",
                       legacy_marker: :execute_waiting, waiting_reason: "no_worktree_changes")
      assert_equal :execute_waiting, first.marker_name

      lost = store.mark_lost(attempt_a, reason: "owner_gone", now: Time.now.utc)
      File.write(File.join(task.worktree_path, "change.txt"), "change\n")
      run!("git", "-C", task.worktree_path, "add", "change.txt")
      run!("git", "-C", task.worktree_path, "commit", "-m", "change", "--quiet")
      attempt_b = store.create_launching(
        **attempt_identity(task, baseline).merge(
          attempt_id: "attempt-b", request_id: "request-b",
          predecessor_attempt_id: lost.attempt_id
        ),
        launch_timeout_sec: 30, now: Time.now.utc
      )
      context_b = Hive::Attempts::Context.new(
        attempt_id: attempt_b.attempt_id, task_generation: 1,
        ownership_generation: attempt_b.ownership_generation
      )
      second = evaluate(task, store, attempt_b, context_b, baseline, mode: "conditions",
                        legacy_marker: :execute_complete)

      assert_equal :execute_complete, second.marker_name
      changes = second.projection.current_condition("ChangesPresent")
      assert_equal "attempt-b", changes.fetch("attempt_id")
      old_wait = second.projection["conditions"].fetch("history").find do |fact|
        fact["condition"] == "AwaitingHuman" && fact["attempt_id"] == "attempt-a"
      end
      assert_equal "newer_incompatible_attempt", old_wait.fetch("superseded_reason")
    end
  end

  def test_research_success_requires_explicit_policy_and_output_evidence
    with_fixture(research: true) do |task, store, attempt, context, baseline|
      denied = evaluate(
        task, store, attempt, context, baseline, mode: "conditions",
        legacy_marker: :execute_complete, research: true, research_evidence: false
      )
      assert_equal :execute_waiting, denied.marker_name

      allowed = evaluate(
        task, store, attempt, context, baseline, mode: "conditions",
        legacy_marker: :execute_complete, research: true, research_evidence: true
      )
      assert_equal :execute_complete, allowed.marker_name
      assert_equal "research", allowed.marker_attrs.fetch(:mode)
      assert_equal "no_commit_success", allowed.gate.waivers.first.fetch("reason")
    end
  end

  def test_transition_guard_blocks_marker_only_bypass_in_condition_mode
    with_fixture do |task, store, attempt, context, baseline|
      outcome = evaluate(task, store, attempt, context, baseline, mode: "conditions",
                         legacy_marker: :execute_complete)
      assert_equal :execute_waiting, outcome.marker_name
      Hive::Markers.set(task.state_file, :execute_complete)

      assert_raises(Hive::WrongStage) do
        Hive::Conditions::TransitionGuard.validate!(task, config: config("conditions"))
      end
      assert Hive::Conditions::TransitionGuard.validate!(task, config: config("markers"))
      assert Hive::Conditions::TransitionGuard.validate!(task, config: config("conditions"), force: true)
    end
  end

  def test_legacy_boundary_writes_baseline_and_snapshot_before_returning_marker_outcome
    with_tmp_git_repo do |worktree|
      with_tmp_dir do |dir|
        task = build_task(dir, worktree)
        baseline = Hive::GitOps.new(worktree).head_sha
        outcome = Hive::Conditions::ExecuteBoundary.new(
          task: task, config: config("conditions"), worktree_path: worktree,
          context: nil, attempt_store: nil
        ).evaluate(
          legacy_marker_name: :execute_complete, legacy_commit: "execute_complete",
          legacy_status: :execute_complete, baseline_head: baseline
        )

        assert_equal "markers", outcome.selection.effective
        assert File.exist?(File.join(dir, "events.jsonl"))
        assert File.exist?(File.join(dir, "task-projection.json"))
        assert_equal :execute_complete, outcome.marker_name
      end
    end
  end

  def test_missing_gate_evidence_triggers_exactly_one_inline_reconciliation
    with_fixture do |task, store, attempt, context, baseline|
      boundary = Hive::Conditions::ExecuteBoundary.new(
        task: task, config: config("conditions"), worktree_path: task.worktree_path,
        attempt_store: store, context: context
      )
      original_gate = boundary.method(:gate_for)
      calls = 0
      boundary.define_singleton_method(:gate_for) do |projection, **options|
        calls += 1
        if calls == 1
          Hive::Conditions::GateResult.new(
            status: :reconcile_required, transition: "execute_to_open_pr",
            diagnostics: [ { "condition" => "ChangesPresent", "state" => "missing" } ],
            waivers: []
          )
        else
          original_gate.call(projection, **options)
        end
      end

      outcome = boundary.evaluate(
        legacy_marker_name: :execute_complete, legacy_commit: "execute_complete",
        legacy_status: :execute_complete, baseline_head: baseline
      )

      assert_equal 2, calls
      assert_equal :execute_waiting, outcome.marker_name
    end
  end

  def test_mismatched_durable_context_fails_before_reconciliation
    with_fixture do |task, store, attempt, _context, baseline|
      mismatched = Hive::Attempts::Context.new(
        attempt_id: attempt.attempt_id, task_generation: 2,
        ownership_generation: attempt.ownership_generation
      )
      boundary = Hive::Conditions::ExecuteBoundary.new(
        task: task, config: config("conditions"), worktree_path: task.worktree_path,
        attempt_store: store, context: mismatched
      )

      assert_raises(Hive::Conditions::GenerationMismatch) do
        boundary.evaluate(
          legacy_marker_name: :execute_complete, legacy_commit: "execute_complete",
          legacy_status: :execute_complete, baseline_head: baseline
        )
      end
      refute File.exist?(File.join(task.folder, "events.jsonl"))
    end
  end

  def test_legacy_boundary_tolerates_unavailable_head_and_branch
    with_tmp_git_repo do |worktree|
      with_tmp_dir do |dir|
        task = build_task(dir, worktree)
        outcome = Hive::Conditions::ExecuteBoundary.new(
          task: task, config: config("markers"), worktree_path: worktree,
          context: nil, attempt_store: nil, git_ops: UnavailableGit.new
        ).evaluate(
          legacy_marker_name: :execute_waiting, legacy_commit: "execute_waiting",
          legacy_status: :execute_waiting, baseline_head: nil
        )

        assert_equal :execute_waiting, outcome.marker_name
      end
    end
  end

  def test_transition_guard_research_probes_fail_closed_on_unreadable_inputs
    with_tmp_dir do |dir|
      task = build_task(dir, dir)
      File.write(File.join(dir, "plan.md"), "---\n[unterminated\n---\n")
      refute Hive::Conditions::TransitionGuard.research_execution?(task)

      File.delete(task.state_file)
      refute Hive::Conditions::TransitionGuard.research_output?(task)
    end
  end

  private

  def with_fixture(research: false)
    with_tmp_git_repo do |worktree|
      with_tmp_dir do |dir|
        task = build_task(dir, worktree, research: research)
        baseline = Hive::GitOps.new(worktree).head_sha
        store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
        attempt = store.create_launching(
          **attempt_identity(task, baseline), launch_timeout_sec: 30, now: Time.now.utc
        )
        context = Hive::Attempts::Context.new(
          attempt_id: attempt.attempt_id, task_generation: 1,
          ownership_generation: attempt.ownership_generation
        )
        yield task, store, attempt, context, baseline
      end
    end
  end

  def build_task(dir, worktree, research: false)
    plan = research ? "---\nexecution_mode: research\n---\nplan\n" : "plan\n"
    File.write(File.join(dir, "plan.md"), plan)
    File.write(File.join(dir, "task.md"), "task\n")
    TaskStub.new(
      folder: dir, state_file: File.join(dir, "task.md"), slug: "task", id: 42,
      worktree_path: worktree, workflow: Hive::Workflows::Coding::DESCRIPTOR,
      stage_index: 4, stage_name: "execute", project_root: worktree
    )
  end

  def attempt_identity(task, baseline)
    policy = task.workflow.stage_named("execute").condition_policy.to_h
    generation = Hive::Attempts::Generation.resolve(
      task: task, project: "demo", intended_stage: "4-execute",
      ownership_generation: "owner-1", task_input_epoch: 1
    )
    {
      attempt_id: "attempt-a", request_id: "request-a", predecessor_attempt_id: nil,
      task_id: "42", project: "demo", task_slug: "task", intended_stage: "4-execute",
      task_generation: generation.ownership_generation,
      ownership_generation: generation.ownership_generation,
      task_input_epoch: generation.task_input_epoch,
      progress_token: Digest::SHA256.hexdigest(Hive::TaskProjection.canonical_json(policy)),
      provider: "codex", starting_revision: baseline,
      retry_charge: 0, inherited_outputs: []
    }
  end

  def evaluate(task, store, attempt, context, baseline, mode:, legacy_marker:,
               waiting_reason: nil, research: false, research_evidence: false)
    Hive::Conditions::ExecuteBoundary.new(
      task: task, config: config(mode), worktree_path: task.worktree_path,
      attempt_store: store, context: context
    ).evaluate(
      legacy_marker_name: legacy_marker,
      legacy_attrs: legacy_marker == :execute_waiting ? { reason: waiting_reason } : {},
      legacy_commit: legacy_marker.to_s,
      legacy_status: legacy_marker,
      baseline_head: baseline,
      waiting_reason: waiting_reason,
      research: research,
      research_evidence: research_evidence
    )
  end

  def config(mode)
    { "conditions" => { "authority" => "markers", "stages" => { "4-execute" => mode } } }
  end
end
