require "test_helper"
require "hive/finalization/outcome_validator"

class FinalizationOutcomeValidatorTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 17, 18, 0, 0)
  TaskDouble = Data.define(:stage_index, :stage_name, :slug, :worktree_path, :project_root)

  def test_abandonment_requires_closed_unmerged_current_pr_and_no_live_claim
    validator = build_validator

    evidence = validator.validate!(**attributes(outcome: "abandonment", evidence: nil))

    assert_equal "abandonment", evidence.fetch("kind")
    assert_equal "CLOSED", evidence.dig("current_pr", "state")
    assert evidence.fetch("no_live_claim")

    open_error = assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
      validator.validate!(**attributes(outcome: "abandonment", evidence: nil,
                                       current_snapshot: snapshot(state: "OPEN")))
    end
    assert_includes open_error.message, "closed without merge"

    live_claim = job.merge("claims" => [ claim(expires_at: NOW + 30) ])
    claim_error = assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
      validator.validate!(**attributes(outcome: "abandonment", evidence: nil, job: live_claim))
    end
    assert_includes claim_error.message, "can still mutate"
  end

  def test_expired_claim_does_not_block_abandonment
    expired = job.merge("claims" => [ claim(expires_at: NOW - 1) ])

    evidence = build_validator.validate!(**attributes(outcome: "abandonment", evidence: nil, job: expired))

    assert evidence.fetch("verified")
  end

  def test_superseded_requires_different_explicitly_merged_pr_on_same_target
    landed = snapshot(number: 13, url: "https://github.com/acme/demo/pull/13",
                      state: "MERGED", merged_at: NOW.iso8601)
    loaded = []
    validator = build_validator(snapshot_loader: lambda { |url, cfg|
      loaded << [ url, cfg ]
      landed
    })

    evidence = validator.validate!(**attributes(outcome: "superseded", evidence: landed.url))

    assert_equal 13, evidence.dig("landed_pr", "number")
    assert_equal [ [ landed.url, {} ] ], loaded

    not_merged = build_validator(snapshot_loader: ->(_url, _cfg) { snapshot(number: 13) })
    error = assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
      not_merged.validate!(**attributes(outcome: "superseded", evidence: landed.url))
    end
    assert_includes error.message, "not explicitly merged"

    wrong_target = build_validator(snapshot_loader: lambda { |_url, _cfg|
      snapshot(number: 13, url: landed.url, state: "MERGED", merged_at: NOW.iso8601,
               base_branch: "release")
    })
    error = assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
      wrong_target.validate!(**attributes(outcome: "superseded", evidence: landed.url))
    end
    assert_includes error.message, "target branch"
  end

  def test_direct_landing_requires_recorded_head_and_remote_containment
    checks = []
    validator = build_validator(landing_checker: lambda { |path, commit, branch, cfg|
      checks << [ path, commit, branch, cfg ]
      true
    })

    evidence = validator.validate!(**attributes(outcome: "direct_landing", evidence: "a" * 40))

    assert_equal "a" * 40, evidence.fetch("commit_sha")
    assert_equal [ [ "/tmp/task-wt", "a" * 40, "main", {} ] ], checks

    mismatch = assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
      validator.validate!(**attributes(outcome: "direct_landing", evidence: "b" * 40))
    end
    assert_includes mismatch.message, "does not match"

    absent = build_validator(landing_checker: ->(*) { false })
    error = assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
      absent.validate!(**attributes(outcome: "direct_landing", evidence: "a" * 40))
    end
    assert_includes error.message, "not contained"
  end

  def test_unknown_outcome_stale_coordinates_and_bad_claim_fail_closed
    assert_raises(Hive::Finalization::OutcomeValidator::InvalidOutcome) do
      build_validator.validate!(**attributes(outcome: "label_says_done", evidence: nil))
    end

    stale = finalization.merge("task_generation" => 4)
    error = assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
      build_validator.validate!(**attributes(outcome: "abandonment", evidence: nil, finalization: stale))
    end
    assert_includes error.message, "stale"

    corrupt = job.merge("claims" => [ claim(expires_at: "not-time") ])
    error = assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
      build_validator.validate!(**attributes(outcome: "abandonment", evidence: nil, job: corrupt))
    end
    assert_includes error.message, "claim evidence is invalid"
  end

  private

  def build_validator(snapshot_loader: ->(_url, _cfg) { raise "unexpected snapshot load" },
                      landing_checker: ->(*) { true })
    Hive::Finalization::OutcomeValidator.new(
      snapshot_loader: snapshot_loader, landing_checker: landing_checker, clock: -> { NOW }
    )
  end

  def attributes(outcome:, evidence:, finalization: self.finalization, job: self.job,
                 current_snapshot: snapshot)
    {
      outcome: outcome, evidence: evidence, finalization: finalization, job: job,
      current_snapshot: current_snapshot, task: task, cfg: {}
    }
  end

  def finalization
    {
      "state" => "blocked", "task_generation" => 3,
      "job_id" => "bsj-v1-#{'1' * 32}", "repository" => "github.com/acme/demo",
      "pr_number" => 12, "pr_url" => "https://github.com/acme/demo/pull/12",
      "head_sha" => "a" * 40, "head_generation" => 1,
      "finalize_attempt_id" => "attempt-1"
    }
  end

  def job
    {
      "job_id" => finalization.fetch("job_id"),
      "identity" => {
        "task_slug" => "durable-task", "task_generation" => 3,
        "repository" => "github.com/acme/demo", "pr_number" => 12
      },
      "pr_url" => finalization.fetch("pr_url"), "head_sha" => "a" * 40,
      "head_generation" => 1, "finalize_attempt_id" => "attempt-1", "claims" => []
    }
  end

  def task
    TaskDouble.new(
      stage_index: 8, stage_name: "finalize", slug: "durable-task",
      worktree_path: "/tmp/task-wt", project_root: "/tmp/project"
    )
  end

  def snapshot(number: 12, url: "https://github.com/acme/demo/pull/12", state: "CLOSED",
               merged_at: nil, base_branch: "main")
    Hive::Gh::PrSnapshot.new(
      repository: "github.com/acme/demo", number: number, url: url, state: state,
      head_sha: "a" * 40, head_branch: "feature/durable", base_branch: base_branch,
      merged_at: merged_at, observed_at: NOW.iso8601(6), mergeable: nil,
      merge_state_status: nil, review_decision: nil, status_check_rollup: []
    )
  end

  def claim(expires_at:)
    { "state" => "active", "expires_at" => expires_at.respond_to?(:iso8601) ? expires_at.iso8601 : expires_at }
  end
end
