require "test_helper"
require "hive/babysitter/job_runner"

class BabysitterJobRunnerTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 17, 16, 0, 0)

  def test_current_green_head_becomes_merge_ready
    with_active_job do |store, job, project|
      snapshot = pr_snapshot
      with_snapshot_and_status(snapshot, ready_status) do
        outcome = run_job(store, job, project)
        projection = projection(job)

        assert_equal :merge_ready, outcome
        assert_equal "merge_ready", projection.fetch("state")
        assert_equal 1, projection.fetch("head_generation")
      end
    end
  end

  def test_new_head_advances_generation_and_invalidates_readiness_before_reassessment
    with_active_job do |store, job, project|
      with_snapshot_and_status(pr_snapshot, ready_status) { run_job(store, job, project) }

      changed = pr_snapshot(head_sha: "b" * 40, observed_at: T0 + 10)
      with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot, ->(*_args, **_kwargs) { changed }) do
        outcome = run_job(store, store.read(job.fetch("job_id")), project, now: T0 + 10)
        current = store.read(job.fetch("job_id"))
        projected = projection(current)

        assert_equal :head_changed, outcome
        assert_equal "b" * 40, current.fetch("head_sha")
        assert_equal 2, current.fetch("head_generation")
        assert_equal "babysitter_active", projected.fetch("state")
        assert_nil projected.dig("evidence", "merge_ready_event_id")
      end
    end
  end

  def test_closed_without_merge_is_a_needs_human_blocker
    with_active_job do |store, job, project|
      snapshot = pr_snapshot(state: "CLOSED")
      with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot, ->(*_args, **_kwargs) { snapshot }) do
        outcome = run_job(store, job, project)
        projected = projection(job)

        assert_equal :needs_human, outcome
        assert_equal "blocked", projected.fetch("state")
        assert_equal "closed_unmerged", projected.dig("blocker", "code")
        assert projected.dig("blocker", "needs_human")
      end
    end
  end

  def test_explicit_merged_snapshot_is_terminal_without_a_readiness_sample
    with_active_job do |store, job, project|
      merged_at = "2026-07-16T23:05:50Z"
      snapshot = pr_snapshot(state: "MERGED", merged_at: merged_at)
      with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot, ->(*_args, **_kwargs) { snapshot }) do
        outcome = run_job(store, job, project)
        projected = projection(job)

        assert_equal :merged, outcome
        assert_equal "merged", projected.fetch("state")
        assert_equal merged_at, projected.dig("evidence", "merged_at")
        assert_nil projected.dig("evidence", "merge_ready_event_id")
        assert_equal "terminal", store.read(job.fetch("job_id")).fetch("state")
      end
    end
  end

  def test_github_failure_is_visible_and_recoverable
    with_active_job do |store, job, project|
      with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot,
                                     ->(*_args, **_kwargs) { raise Hive::GhError, "rate limited" }) do
        outcome = run_job(store, job, project)
        projected = projection(job)

        assert_equal :blocked, outcome
        assert_equal "blocked", projected.fetch("state")
        assert_equal "github_unavailable", projected.dig("blocker", "code")
        refute projected.dig("blocker", "needs_human")
        assert_equal "active", store.read(job.fetch("job_id")).fetch("state")
      end
    end
  end

  def test_stale_authority_and_stale_release_are_inert
    with_active_job do |store, job, project|
      with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot, lambda { |*_args, **_kwargs|
        raise Hive::TaskJournal::AttemptMismatch, "attempt changed"
      }) do
        with_replaced_singleton_method(store, :release!, lambda { |*_args, **_kwargs|
          raise Hive::Babysitter::JobStore::StaleClaim, "taken over"
        }) do
          assert_equal :stale_claim, run_job(store, job, project)
        end
      end
    end
  end

  def test_sanctioned_push_rechecks_the_exact_remote_head
    with_active_job do |store, job, project|
      snapshots = [ pr_snapshot, pr_snapshot(head_sha: "b" * 40) ]
      pending = pending_status
      fixer = lambda do |*_args, **kwargs|
        kwargs.fetch(:push_authorizer).call
        :success
      end
      with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot,
                                     ->(*_args, **_kwargs) { snapshots.shift || snapshots.last }) do
        with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(*_args, **_kwargs) { pending }) do
          with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, fixer) do
            assert_equal :stale_claim, run_job(store, job, project)
          end
        end
      end
    end
  end

  def test_remediation_observes_a_runner_created_head
    with_active_job do |store, job, project|
      snapshots = [ pr_snapshot, pr_snapshot, pr_snapshot(head_sha: "b" * 40, observed_at: T0 + 1) ]
      pending = pending_status
      authorized = false
      fixer = lambda do |*_args, **kwargs|
        authorized = kwargs.fetch(:push_authorizer).call
        :success
      end
      with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot,
                                     ->(*_args, **_kwargs) { snapshots.shift }) do
        with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(*_args, **_kwargs) { pending }) do
          with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, fixer) do
            assert_equal :head_changed, run_job(store, job, project)
            assert authorized
            assert_equal 2, store.read(job.fetch("job_id")).fetch("head_generation")
          end
        end
      end
    end
  end

  def test_remediation_refresh_observes_terminal_states
    [ [ "MERGED", :merged ], [ "CLOSED", :needs_human ] ].each do |state, expected|
      with_active_job do |store, job, project|
        pending = pending_status
        terminal = pr_snapshot(
          state: state, merged_at: (T0 + 1).iso8601(6), observed_at: T0 + 1
        )
        terminal = terminal.with(merged_at: nil) if state == "CLOSED"
        snapshots = [ pr_snapshot, pr_snapshot, terminal ]
        fixer = lambda do |*_args, **kwargs|
          kwargs.fetch(:push_authorizer).call
          :success
        end
        with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot,
                                       ->(*_args, **_kwargs) { snapshots.shift }) do
          with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(*_args, **_kwargs) { pending }) do
            with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, fixer) do
              assert_equal expected, run_job(store, job, project)
            end
          end
        end
      end
    end
  end

  def test_remediation_refresh_rechecks_readiness_and_human_blockers
    [
      [ ready_status, :merge_ready ],
      [ pending_status.merge("reviewDecision" => "REVIEW_REQUIRED"), :needs_human ]
    ].each do |refreshed_status, expected|
      with_active_job do |store, job, project|
        snapshots = [ pr_snapshot, pr_snapshot, pr_snapshot ]
        statuses = [ pending_status, refreshed_status ]
        fixer = lambda do |*_args, **kwargs|
          kwargs.fetch(:push_authorizer).call
          :success
        end
        with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot,
                                       ->(*_args, **_kwargs) { snapshots.shift }) do
          with_replaced_singleton_method(Hive::Gh, :pr_status_rollup,
                                         ->(*_args, **_kwargs) { statuses.shift }) do
            with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, fixer) do
              assert_equal expected, run_job(store, job, project)
            end
          end
        end
      end
    end
  end

  def test_status_rollup_head_movement_is_refreshed_before_decision
    with_active_job do |store, job, project|
      snapshots = [ pr_snapshot, pr_snapshot ]
      moved_status = pending_status.merge("headRefOid" => "b" * 40)
      with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot,
                                     ->(*_args, **_kwargs) { snapshots.shift }) do
        with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(*_args, **_kwargs) { moved_status }) do
          assert_equal :blocked, run_job(store, job, project)
          assert_equal "stale_status_snapshot", projection(job).dig("blocker", "code")
        end
      end
    end

    with_active_job do |store, job, project|
      snapshots = [ pr_snapshot, pr_snapshot(head_sha: "b" * 40, observed_at: T0 + 1) ]
      moved_status = pending_status.merge("headRefOid" => "b" * 40)
      with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot,
                                     ->(*_args, **_kwargs) { snapshots.shift }) do
        with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(*_args, **_kwargs) { moved_status }) do
          assert_equal :head_changed, run_job(store, job, project)
        end
      end
    end
  end

  def test_snapshot_identity_status_and_blocker_helpers_are_closed
    job = {
      "identity" => { "repository" => "github.com/acme/demo", "pr_number" => 12 },
      "pr_url" => "https://github.com/acme/demo/pull/12"
    }
    assert_raises(Hive::GhError) do
      Hive::Babysitter::JobRunner.validate_snapshot_identity!(job, pr_snapshot(number: 13))
    end

    embedded = pr_snapshot.with(
      mergeable: "MERGEABLE", merge_state_status: "CLEAN", review_decision: "APPROVED",
      status_check_rollup: [ { "conclusion" => "SUCCESS" } ]
    )
    status = Hive::Babysitter::JobRunner.status_for(embedded, { "path" => "/tmp" }, {})
    assert Hive::Babysitter::JobRunner.ready?(status)
    assert_equal "review_required",
                 Hive::Babysitter::JobRunner.blocker_for(status.merge("reviewDecision" => "CHANGES_REQUESTED")).first
    assert_equal "checks_failed",
                 Hive::Babysitter::JobRunner.blocker_for(status.merge(
                   "statusCheckRollup" => [ { "conclusion" => "FAILURE" } ]
                 )).first
    assert_equal "checks_pending",
                 Hive::Babysitter::JobRunner.blocker_for(status.merge(
                   "statusCheckRollup" => [ { "conclusion" => "" } ]
                 )).first
    assert_equal "mergeability_blocked",
                 Hive::Babysitter::JobRunner.blocker_for(status.merge("mergeable" => "CONFLICTING")).first
    assert_equal 12, Hive::Babysitter::JobRunner.pr_hash(embedded, status).fetch("number")
  end

  def test_stale_claim_operational_event_is_best_effort
    emitted = nil
    project = { "name" => "demo", "path" => "/tmp" }
    job = { "identity" => { "pr_number" => 12 }, "job_id" => "job", "head_sha" => "a" * 40,
            "head_generation" => 1 }
    with_replaced_singleton_method(Hive::Babysitter::Events, :emit, lambda { |**fields| emitted = fields }) do
      Hive::Babysitter::JobRunner.emit_operational(
        project, job, { "claim_fence" => 2 }, :stale_claim
      )
    end
    assert_equal "stale_claim", emitted.fetch(:outcome)

    with_replaced_singleton_method(Hive::Babysitter::Events, :emit, lambda { |**fields| emitted = fields }) do
      Hive::Babysitter::JobRunner.emit_operational(
        project, job, { "claim_fence" => 2 }, :active
      )
    end
    assert_equal "active", emitted.fetch(:outcome)
  end

  private

  def with_active_job
    with_tmp_dir do |root|
      task_folder = File.join(root, ".hive-state", "stages", "8-finalize", "durable-task")
      FileUtils.mkdir_p(task_folder)
      store = Hive::Babysitter::JobStore.new(project_root: root, clock: -> { T0 })
      job = store.reserve!(
        project: "demo", task_id: 42, task_slug: "durable-task", task_generation: 3,
        repository: "github.com/acme/demo", pr_number: 12,
        pr_url: "https://github.com/acme/demo/pull/12", branch: "feature/durable",
        head_sha: "a" * 40, head_generation: 1, finalize_attempt_id: "attempt-1",
        task_folder: task_folder, now: T0
      )
      write_handoff(task_folder, job)
      job = store.activate!(job.fetch("job_id"), handoff_event_id: "finalized",
                            finalize_attempt_id: "attempt-1", now: T0)
      project = { "name" => "demo", "path" => root,
                  "hive_state_path" => File.join(root, ".hive-state") }
      yield store, job, project
    end
  end

  def run_job(store, job, project, now: T0)
    Hive::Babysitter::JobRunner.run(
      job: job, store: store, project: project,
      cfg: { "babysitter" => { "budget_minutes" => 5 } },
      dry_run: false, logger: nil, inflight: Set.new, now: now, owner: "daemon-a"
    )
  end

  def with_snapshot_and_status(snapshot, status)
    with_replaced_singleton_method(Hive::Gh, :exact_pr_snapshot, ->(*_args, **_kwargs) { snapshot }) do
      with_replaced_singleton_method(Hive::Gh, :pr_status_rollup, ->(*_args, **_kwargs) { status }) do
        yield
      end
    end
  end

  def ready_status
    {
      "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN",
      "reviewDecision" => "APPROVED", "headRefOid" => "a" * 40,
      "statusCheckRollup" => [ { "conclusion" => "SUCCESS" } ]
    }
  end

  def pr_snapshot(state: "OPEN", head_sha: "a" * 40, merged_at: nil, observed_at: T0,
                  number: 12)
    Hive::Gh::PrSnapshot.new(
      repository: "github.com/acme/demo", number: number,
      url: "https://github.com/acme/demo/pull/#{number}", state: state,
      head_sha: head_sha, head_branch: "feature/durable", base_branch: "main",
      merged_at: merged_at, observed_at: observed_at.utc.iso8601(6),
      mergeable: nil, merge_state_status: nil, review_decision: nil,
      status_check_rollup: nil
    )
  end

  def pending_status
    {
      "mergeable" => "UNKNOWN", "mergeStateStatus" => "BLOCKED",
      "reviewDecision" => "", "headRefOid" => "a" * 40,
      "statusCheckRollup" => [ { "conclusion" => "" } ]
    }
  end

  def projection(job)
    records = Hive::TaskProjection.read_journal(File.join(job.fetch("task_folder"), "events.jsonl"))
    Hive::Finalization::Projection.project(records: records)
  end

  def write_handoff(task_folder, job)
    identity = job.fetch("identity")
    payload = {
      "job_id" => job.fetch("job_id"), "repository" => identity.fetch("repository"),
      "pr_number" => identity.fetch("pr_number"), "pr_url" => job.fetch("pr_url"),
      "head_sha" => job.fetch("head_sha"), "head_generation" => job.fetch("head_generation"),
      "finalize_attempt_id" => "attempt-1"
    }
    event = Hive::TaskJournal::Envelope.authoritative({
      event_type: "finalized", event_id: "finalized", occurred_at: T0.iso8601(6),
      observed_at: T0.iso8601(6), task: { "id" => "42", "slug" => "durable-task" },
      workflow: "coding", stage: "8-finalize", attempt_id: "attempt-1", task_generation: 3,
      ownership_generation: "owner-1", reason: "handoff", evidence: [],
      provenance: { "source" => "test" },
      producer: { "kind" => "finalize_attempt", "attempt_id" => "attempt-1" }, payload: payload
    })
    File.write(File.join(task_folder, "events.jsonl"), "#{JSON.generate(event)}\n")
  end
end
