require "test_helper"
require "hive/conditions/reconcilers/execute"
require "hive/attempts/store"

class ConditionsReconcilersExecuteTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(:folder, :state_file, :slug, :id, :worktree_path, :workflow, keyword_init: true)

  class BrokenGit
    def head_sha = raise(Hive::GitError, "head unavailable")
  end

  def test_clean_coding_attempt_records_explicit_negative_and_wait_then_commit_supersedes_it
    with_fixture do |task, store, attempt, baseline|
      reconciler = build_reconciler(task, store, attempt)
      first = reconciler.reconcile(baseline_head: baseline)

      assert_equal %w[
        generation_advanced commit_generation_advanced condition_observed
        condition_observed condition_observed
      ], first.observations.map { |event| event.fetch(:event_type) }
      assert_equal "unsatisfied", first.projection.current_condition("ChangesPresent").fetch("state")
      assert_equal "no_worktree_changes", first.projection.current_condition("ChangesPresent").fetch("reason")
      assert_equal "satisfied", first.projection.current_condition("AwaitingHuman").fetch("state")

      File.write(File.join(task.worktree_path, "change.txt"), "change\n")
      run!("git", "-C", task.worktree_path, "add", "change.txt")
      run!("git", "-C", task.worktree_path, "commit", "-m", "change", "--quiet")
      second = reconciler.reconcile(baseline_head: baseline)

      assert_equal "satisfied", second.projection.current_condition("ChangesPresent").fetch("state")
      assert_equal "unsatisfied", second.projection.current_condition("AwaitingHuman").fetch("state")
      assert_equal 2, second.projection["identity"].fetch("commit_generation")
      historical_wait = second.projection["conditions"].fetch("history").find do |fact|
        fact["condition"] == "AwaitingHuman" && fact["original_state"] == "satisfied"
      end
      assert historical_wait

      journal_size = File.size(File.join(task.folder, "task-journal.jsonl"))
      repeated = reconciler.reconcile(baseline_head: baseline)
      assert_nil repeated.append_result
      assert_equal journal_size, File.size(File.join(task.folder, "task-journal.jsonl"))
    end
  end

  def test_research_policy_records_no_change_honestly_without_activating_wait
    with_fixture do |task, store, attempt, baseline|
      result = build_reconciler(task, store, attempt).reconcile(
        baseline_head: baseline, research: true
      )

      assert_equal "unsatisfied", result.projection.current_condition("ChangesPresent").fetch("state")
      assert_equal "research_no_commit", result.projection.current_condition("ChangesPresent").fetch("reason")
      assert_equal "unsatisfied", result.projection.current_condition("AwaitingHuman").fetch("state")

      with_output = build_reconciler(task, store, attempt).reconcile(
        baseline_head: baseline, research: true, research_evidence: true
      )
      changes = with_output.projection.current_condition("ChangesPresent")
      assert_equal true, changes.dig("payload", "research_output_evidence")
      assert changes.fetch("evidence").any? do |entry|
        entry["type"] == "file" && entry["purpose"] == "research_output"
      end
    end
  end

  def test_unreadable_research_output_is_not_claimed_as_durable_evidence
    with_fixture do |task, store, attempt, baseline|
      original_file = Digest::SHA256.method(:file)
      replacement = lambda do |path|
        raise Errno::EACCES, path if path == task.state_file

        original_file.call(path)
      end

      result = with_replaced_singleton_method(Digest::SHA256, :file, replacement) do
        build_reconciler(task, store, attempt).reconcile(
          baseline_head: baseline, research: true, research_evidence: true
        )
      end

      changes = result.projection.current_condition("ChangesPresent")
      assert_equal false, changes.dig("payload", "research_output_evidence")
      refute changes.fetch("evidence").any? { |entry| entry["purpose"] == "research_output" }
    end
  end

  def test_dirty_and_unverifiable_evidence_are_explicit_observations
    with_fixture do |task, store, attempt, baseline|
      File.write(File.join(task.worktree_path, "dirty.txt"), "dirty\n")
      dirty = build_reconciler(task, store, attempt).reconcile(baseline_head: baseline)
      assert_equal "satisfied", dirty.projection.current_condition("ChangesPresent").fetch("state")
      assert_equal "dirty_worktree", dirty.projection.current_condition("AwaitingHuman").fetch("reason")
    end

    with_fixture do |task, store, attempt, baseline|
      unavailable = build_reconciler(task, store, attempt, git_ops: BrokenGit.new)
                    .reconcile(baseline_head: baseline)
      changes = unavailable.projection.current_condition("ChangesPresent")
      assert_equal "unverifiable", changes.fetch("state")
      assert_equal "worktree_evidence_unverifiable", changes.fetch("reason")
      assert_equal "evidence_unverifiable",
                   unavailable.projection.current_condition("AwaitingHuman").fetch("reason")
    end
  end

  def test_lost_attempt_is_unhealthy_and_generation_mismatch_fails_closed
    with_fixture do |task, store, attempt, baseline|
      lost = store.mark_lost(attempt, reason: "owner_gone", now: Time.now.utc)
      result = build_reconciler(task, store, lost).reconcile(baseline_head: baseline)
      assert_equal "unsatisfied", result.projection.current_condition("AgentHealthy").fetch("state")
      assert_equal "attempt_lost", result.projection.current_condition("AgentHealthy").fetch("reason")
    end

    with_fixture(task_input_epoch: 9) do |task, store, attempt, baseline|
      assert_raises(Hive::Conditions::GenerationMismatch) do
        build_reconciler(task, store, attempt).reconcile(baseline_head: baseline)
      end
      refute File.exist?(File.join(task.folder, "task-journal.jsonl"))
    end
  end

  def test_terminal_attempt_health_preserves_success_or_failure
    %w[succeeded failed].each do |outcome|
      with_fixture do |task, store, attempt, baseline|
        terminal = terminalize(store, attempt, outcome: outcome)
        result = build_reconciler(task, store, terminal).reconcile(baseline_head: baseline)
        health = result.projection.current_condition("AgentHealthy")

        assert_equal(outcome == "succeeded" ? "satisfied" : "unsatisfied", health.fetch("state"))
        assert_equal "attempt_terminal_#{outcome}", health.fetch("reason")
        assert_equal outcome == "succeeded",
                     health.dig("payload", "informational_after_terminal")
      end
    end
  end

  def test_unrecognized_but_durable_attempt_state_is_unverifiable
    with_fixture do |task, store, attempt, baseline|
      unusual = attempt.dup
      unusual.define_singleton_method(:state) { "future_state" }
      unusual.define_singleton_method(:live?) { false }
      unusual.define_singleton_method(:final?) { false }

      result = build_reconciler(task, store, unusual).reconcile(baseline_head: baseline)
      health = result.projection.current_condition("AgentHealthy")
      assert_equal "unverifiable", health.fetch("state")
      assert_equal "attempt_state_unverifiable", health.fetch("reason")
    end
  end

  private

  def with_fixture(task_input_epoch: 1)
    with_tmp_git_repo do |worktree|
      with_tmp_dir do |state_root|
        task_folder = File.join(state_root, "task-folder")
        FileUtils.mkdir_p(task_folder)
        File.write(File.join(task_folder, "plan.md"), "plan\n")
        state_file = File.join(task_folder, "task.md")
        File.write(state_file, "state\n")
        workflow = Struct.new(:id).new("coding")
        task = TaskStub.new(
          folder: task_folder, state_file: state_file, slug: "task", id: 42,
          worktree_path: worktree, workflow: workflow
        )
        baseline = Hive::GitOps.new(worktree).head_sha
        store = Hive::Attempts::Store.new(root: File.join(state_root, "attempts"))
        attempt = store.create_launching(
          attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
          task_id: "42", project: "demo", task_slug: "task", intended_stage: "4-execute",
          task_generation: "owner-1", task_input_epoch: task_input_epoch,
          progress_token: "progress", provider: "codex",
          worker_argv: [ "hive", "run", task.slug ],
          claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
          starting_revision: baseline,
          retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: Time.now.utc
        )
        yield task, store, attempt, baseline
      end
    end
  end

  def build_reconciler(task, store, attempt, git_ops: nil)
    Hive::Conditions::Reconcilers::Execute.new(
      task: task, attempt: attempt, attempt_store: store, git_ops: git_ops
    )
  end

  def terminalize(store, attempt, outcome:)
    now = Time.now.utc
    claimed = store.claim(
      attempt, owner: { "pid" => 1 }, claim_capability: "c" * 64,
      first_heartbeat_timeout_sec: 30, now: now
    )
    running = store.first_heartbeat(claimed, stale_sec: 30, now: now)
    store.terminalize(
      running, outcome: outcome, exit_status: outcome == "succeeded" ? 0 : 1,
      final_checkpoint: { "revision" => running["latest_revision"], "progress_token" => "progress" },
      output_references: [],
      log_reference: { "path" => "logs/attempt.frames", "size" => 1, "sha256" => "a" * 64 },
      now: now + 1
    )
  end
end
