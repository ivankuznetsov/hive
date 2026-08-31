require "test_helper"
require "hive/proposals/decision_service"

class ProposalDecisionServiceTest < Minitest::Test
  include HiveTestHelper

  class FakeGitOps
    attr_reader :hive_state_path, :commits

    def initialize(hive_state_path, fail_commit: false, fail_reset: false)
      @hive_state_path = hive_state_path
      @fail_commit = fail_commit
      @fail_reset = fail_reset
      @commits = []
    end

    def hive_commit(**options)
      commits << options
      raise Hive::GitError, "simulated lifecycle commit failure" if @fail_commit
      :committed
    end

    def run_git!(*_arguments)
      raise Hive::GitError, "simulated reset failure" if @fail_reset
      true
    end
  end

  def setup
    @tmp = Dir.mktmpdir("proposal-decisions")
    @next_id = 0
    @id_mutex = Mutex.new
    @store = Hive::Proposals::Store.new(
      root: @tmp,
      id_generator: lambda do
        @id_mutex.synchronize do
          @next_id += 1
          format("00000000-0000-4000-8000-%012d", @next_id)
        end
      end
    )
    @authority = Hive::Proposals::Authority.new(
      {
        "authorities" => {
          "alice" => {
            "kind" => "operator", "capabilities" => %w[decide supersede rollback],
            "version" => 1, "revoked" => false
          },
          "reviewer" => {
            "kind" => "operator", "capabilities" => [],
            "version" => 1, "revoked" => false
          }
        }
      }
    )
    @service = Hive::Proposals::DecisionService.new(
      store: @store, authority: @authority,
      clock: -> { Time.utc(2026, 8, 30, 12, 30, 0) }
    )
    create_record(proposal_id)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_decision_snapshots_considered_evidence_and_unrelated_later_evidence_survives
    first = append_evaluation(proposal_id, source: "b", outcome: "pass", metric: 0.91)
    observation = @store.projection(proposal_id).lifecycle_head
    result = decide(
      outcome: "accepted", considered_evaluation_ids: [ first.event_id ],
      expected_head: observation, idempotency_key: "accept-v2"
    )

    assert result.applied
    assert_equal "accepted", result.projection.status
    assert_equal [ first.event_id ], result.event.data.fetch("considered_evaluation_ids")
    assert_equal "benchmark-reviewer",
                 result.event.data.dig("considered_evaluations", 0, "evaluator_id")

    append_evaluation(proposal_id, source: "c", outcome: "mixed", metric: 0.88)
    projection = @store.projection(proposal_id)
    assert_equal "accepted", projection.status
    assert_equal 2, projection.evaluations.length
    assert_equal [ first.event_id ], projection.decision.fetch("considered_evaluation_ids")
  end

  def test_unrelated_evaluation_does_not_stale_a_fixed_head_but_lifecycle_change_does
    first = append_evaluation(proposal_id, source: "b", outcome: "pass", metric: 0.91)
    observation = @store.projection(proposal_id).lifecycle_head
    append_evaluation(proposal_id, source: "c", outcome: "fail", metric: 0.5)

    result = decide(
      outcome: "accepted", considered_evaluation_ids: [ first.event_id ],
      expected_head: observation, idempotency_key: "streaming-decision"
    )
    assert result.applied

    assert_raises(Hive::Proposals::StaleObservation) do
      @service.rollback(
        proposal_id:, reverted_revision: "v2", reason: "regression",
        external_revert: { "kind" => "commit", "reference" => "d" * 40 },
        expected_head: observation, **authority_args("stale-rollback")
      )
    end
  end

  def test_terminal_retry_is_a_noop_and_conflicting_decisions_are_refused
    evaluation = append_evaluation(proposal_id, source: "b", outcome: "pass", metric: 0.91)
    observation = @store.projection(proposal_id).lifecycle_head
    first = decide(
      outcome: "accepted", considered_evaluation_ids: [ evaluation.event_id ],
      expected_head: observation, idempotency_key: "same-source"
    )
    replay = decide(
      outcome: "accepted", considered_evaluation_ids: [ evaluation.event_id ],
      expected_head: observation, idempotency_key: "same-source"
    )

    assert first.applied
    refute replay.applied
    assert_equal first.event.event_id, replay.event.event_id
    assert_raises(Hive::Proposals::Conflict) do
      decide(
        outcome: "rejected", considered_evaluation_ids: [ evaluation.event_id ],
        expected_head: observation, idempotency_key: "other-source"
      )
    end
  end

  def test_unevaluated_rejection_requires_the_closed_no_evaluation_category
    head = @store.projection(proposal_id).lifecycle_head
    assert_raises(Hive::Proposals::InvalidEvent) do
      decide(
        outcome: "accepted", considered_evaluation_ids: [], expected_head: head,
        idempotency_key: "unevaluated-accept", rationale_category: "evaluated"
      )
    end

    result = decide(
      outcome: "rejected", considered_evaluation_ids: [], expected_head: head,
      idempotency_key: "unevaluated-reject", rationale_category: "no_evaluation"
    )
    assert_equal "rejected", result.projection.status
  end

  def test_authority_supersedes_a_matching_successor_and_rollback_preserves_acceptance
    successor = "prp-00000000-0000-4000-8000-000000000002"
    create_record(successor, requested_supersedes: proposal_id)
    supersession = @service.supersede(
      proposal_id:, successor_id: successor,
      expected_head: @store.projection(proposal_id).lifecycle_head,
      **authority_args("supersede-v2")
    )
    assert_equal "superseded", supersession.projection.status
    assert_equal proposal_id, @store.projection(successor).supersedes.first
    replay = @service.supersede(
      proposal_id:, successor_id: successor,
      expected_head: { "version" => 0,
                       "digest" => Hive::Proposals::Projection.empty_head_digest(proposal_id) },
      **authority_args("supersede-v2")
    )
    assert replay.noop?

    accepted = "prp-00000000-0000-4000-8000-000000000003"
    create_record(accepted)
    evaluation = append_evaluation(accepted, source: "f", outcome: "pass", metric: 0.9)
    @service.decide(
      proposal_id: accepted, outcome: "accepted",
      considered_evaluation_ids: [ evaluation.event_id ], rationale_category: "evaluated",
      rationale: "accepted", links: [], expected_head: @store.projection(accepted).lifecycle_head,
      **authority_args("accept-before-rollback")
    )
    rollback = @service.rollback(
      proposal_id: accepted, reverted_revision: "v2", reason: "production regression",
      external_revert: { "kind" => "commit", "reference" => "d" * 40 },
      expected_head: @store.projection(accepted).lifecycle_head,
      **authority_args("rollback-v2")
    )
    assert_equal "rolled_back", rollback.projection.status
    assert_equal "accepted", rollback.projection.decision.fetch("outcome")
    assert_equal "d" * 40, rollback.projection.rollback.dig("external_revert", "reference")
    rollback_replay = @service.rollback(
      proposal_id: accepted, reverted_revision: "v2", reason: "production regression",
      external_revert: { "kind" => "commit", "reference" => "d" * 40 },
      expected_head: rollback.event.data.fetch("observed_head"),
      **authority_args("rollback-v2")
    )
    assert rollback_replay.noop?
  end

  def test_lifecycle_rejects_duplicate_evidence_missing_candidates_and_changed_idempotency
    evaluation = append_evaluation(proposal_id, source: "b", outcome: "pass", metric: 0.91)
    head = @store.projection(proposal_id).lifecycle_head
    assert_raises(Hive::Proposals::StaleObservation) do
      decide(
        outcome: "accepted", considered_evaluation_ids: [ evaluation.event_id, evaluation.event_id ],
        expected_head: head, idempotency_key: "duplicate-evidence"
      )
    end

    decide(
      outcome: "accepted", considered_evaluation_ids: [ evaluation.event_id ],
      expected_head: head, idempotency_key: "immutable-decision"
    )
    assert_raises(Hive::Proposals::Conflict) do
      @service.decide(
        proposal_id:, outcome: "accepted", considered_evaluation_ids: [ evaluation.event_id ],
        rationale_category: "evaluated", rationale: "changed rationale", links: [],
        expected_head: head, **authority_args("immutable-decision")
      )
    end

    assert_raises(Hive::Proposals::InvalidRecord) do
      @service.decide(
        proposal_id: "prp-00000000-0000-4000-8000-000000000099", outcome: "rejected",
        considered_evaluation_ids: [], rationale_category: "no_evaluation", rationale: "missing",
        links: [], expected_head: head, **authority_args("missing-candidate")
      )
    end
  end

  def test_rollback_requires_acceptance_and_the_exact_accepted_revision
    head = @store.projection(proposal_id).lifecycle_head
    assert_raises(Hive::Proposals::Conflict) do
      @service.rollback(
        proposal_id:, reverted_revision: "v2", reason: "not accepted",
        external_revert: { "kind" => "commit", "reference" => "d" * 40 },
        expected_head: head, **authority_args("draft-rollback")
      )
    end

    evaluation = append_evaluation(proposal_id, source: "b", outcome: "pass", metric: 0.91)
    @service.decide(
      proposal_id:, outcome: "accepted", considered_evaluation_ids: [ evaluation.event_id ],
      rationale_category: "evaluated", rationale: "accepted", links: [],
      expected_head: head, **authority_args("accept-for-wrong-revision")
    )
    assert_raises(Hive::Proposals::Conflict) do
      @service.rollback(
        proposal_id:, reverted_revision: "v3", reason: "wrong revision",
        external_revert: { "kind" => "commit", "reference" => "d" * 40 },
        expected_head: @store.projection(proposal_id).lifecycle_head,
        **authority_args("wrong-revision")
      )
    end
  end

  def test_supersession_requires_matching_subjects_and_immutable_retry_data
    mismatch = "prp-00000000-0000-4000-8000-000000000002"
    create_record(mismatch, requested_supersedes: proposal_id, subject_ref: "agent-skills/planner")
    assert_raises(Hive::Proposals::Conflict) do
      @service.supersede(
        proposal_id:, successor_id: mismatch,
        expected_head: @store.projection(proposal_id).lifecycle_head,
        **authority_args("mismatched-subject")
      )
    end

    successor = "prp-00000000-0000-4000-8000-000000000003"
    other = "prp-00000000-0000-4000-8000-000000000004"
    create_record(successor, requested_supersedes: proposal_id)
    create_record(other, requested_supersedes: proposal_id)
    head = @store.projection(proposal_id).lifecycle_head
    @service.supersede(
      proposal_id:, successor_id: successor, expected_head: head,
      **authority_args("immutable-supersession")
    )
    assert_raises(Hive::Proposals::Conflict) do
      @service.supersede(
        proposal_id:, successor_id: other, expected_head: head,
        **authority_args("immutable-supersession")
      )
    end
  end

  def test_evaluator_only_identity_cannot_change_lifecycle
    evaluation = append_evaluation(proposal_id, source: "b", outcome: "pass", metric: 0.91)
    assert_raises(Hive::Proposals::Unauthorized) do
      @service.decide(
        proposal_id:, outcome: "accepted", considered_evaluation_ids: [ evaluation.event_id ],
        rationale_category: "evaluated", rationale: "accept", links: [],
        expected_head: @store.projection(proposal_id).lifecycle_head,
        authority_identity: "reviewer",
        expected_policy_fingerprint: @authority.fingerprint("reviewer"),
        idempotency_key: "reviewer-cannot-decide", provenance: provenance
      )
    end
  end

  def test_concurrent_conflicting_decisions_admit_exactly_one_terminal_fact
    evaluation = append_evaluation(proposal_id, source: "b", outcome: "pass", metric: 0.91)
    observation = @store.projection(proposal_id).lifecycle_head
    gate = Queue.new
    outcomes = Queue.new
    threads = %w[accepted rejected].map do |outcome|
      Thread.new do
        gate.pop
        result = decide(
          outcome:, considered_evaluation_ids: [ evaluation.event_id ],
          expected_head: observation, idempotency_key: "race-#{outcome}"
        )
        outcomes << result
      rescue StandardError => error
        outcomes << error
      end
    end
    threads.length.times { gate << true }
    threads.each(&:join)
    values = threads.length.times.map { outcomes.pop }

    assert_equal 1, values.count { |value| value.is_a?(Hive::Proposals::LifecycleResult) },
                 values.map { |value| [ value.class.name, value.message ] if value.is_a?(Exception) }.inspect
    assert_equal 1, values.count { |value| value.is_a?(Hive::Proposals::Conflict) }
    assert_includes %w[accepted rejected], @store.projection(proposal_id).status
    assert_equal 1, @store.projection(proposal_id).events.count { |event| event.type == "decision" }
  end

  def test_supersession_requires_explicit_matching_successor_intent
    successor = "prp-00000000-0000-4000-8000-000000000002"
    create_record(successor)

    assert_raises(Hive::Proposals::Conflict) do
      @service.supersede(
        proposal_id:, successor_id: successor,
        expected_head: @store.projection(proposal_id).lifecycle_head,
        **authority_args("unrequested-supersession")
      )
    end
    assert_equal "draft", @store.projection(proposal_id).status
  end

  def test_lifecycle_commit_is_exact_and_a_failed_commit_restores_the_event_directory
    evaluation = append_evaluation(proposal_id, source: "b", outcome: "pass", metric: 0.91)
    observation = @store.projection(proposal_id).lifecycle_head
    git_ops = FakeGitOps.new(@tmp)
    service = Hive::Proposals::DecisionService.new(
      store: @store, authority: @authority, git_ops:,
      clock: -> { Time.utc(2026, 8, 30, 12, 30, 0) }
    )
    result = service.decide(
      proposal_id:, outcome: "accepted", considered_evaluation_ids: [ evaluation.event_id ],
      rationale_category: "evaluated", rationale: "accept", links: [], expected_head: observation,
      **authority_args("committed-lifecycle")
    )

    assert_equal [ @store.path_for_event(result.event).delete_prefix("#{@tmp}/") ],
                 git_ops.commits.first.fetch(:pathspecs)

    failing_id = "prp-00000000-0000-4000-8000-000000000004"
    create_record(failing_id)
    failing_evaluation = append_evaluation(failing_id, source: "h", outcome: "pass", metric: 0.9)
    failing = Hive::Proposals::DecisionService.new(
      store: @store, authority: @authority,
      git_ops: FakeGitOps.new(@tmp, fail_commit: true, fail_reset: true),
      clock: -> { Time.utc(2026, 8, 30, 12, 30, 0) }
    )
    assert_raises(Hive::GitError) do
      failing.decide(
        proposal_id: failing_id, outcome: "accepted",
        considered_evaluation_ids: [ failing_evaluation.event_id ],
        rationale_category: "evaluated", rationale: "accept", links: [],
        expected_head: @store.projection(failing_id).lifecycle_head,
        **authority_args("failed-lifecycle")
      )
    end
    assert_equal "draft", @store.projection(failing_id).status
    assert_equal [ "evaluation" ], @store.projection(failing_id).events.map(&:type)
  end

  private

  def proposal_id = "prp-00000000-0000-4000-8000-000000000001"

  def create_record(id, requested_supersedes: nil, subject_ref: "agent-skills/reviewer")
    @store.create_record!(
      proposal_id: id, subject_kind: "skill", subject_ref:,
      revision: "v2", proposed_change: "Change review", motivation: "Improve recall",
      evidence: [ evidence ], author: author,
      lineage: { "requested_supersedes" => requested_supersedes },
      provenance: provenance, source_event_id: source_id(id[-2..]),
      created_at: "2026-08-30T12:00:00Z", policy: policy
    )
  end

  def append_evaluation(id, source:, outcome:, metric:)
    @store.append_event!(
      proposal_id: id, type: "evaluation",
      data: {
        "evaluator" => {
          "id" => "benchmark-reviewer", "binding_fingerprint" => "b" * 64,
          "configuration_fingerprint" => "c" * 64
        },
        "method" => { "kind" => "benchmark", "label" => "held-out recall" },
        "result" => { "outcome" => outcome, "metrics" => { "recall" => metric } },
        "rationale" => "benchmark result", "evidence" => [ evidence ], "links" => []
      },
      source_event_id: source_id(source), provenance: provenance,
      occurred_at: "2026-08-30T12:10:00Z", policy: policy
    )
  end

  def decide(outcome:, considered_evaluation_ids:, expected_head:, idempotency_key:,
             rationale_category: "evaluated")
    @service.decide(
      proposal_id:, outcome:, considered_evaluation_ids:, rationale_category:,
      rationale: "lifecycle decision", links: [], expected_head:,
      **authority_args(idempotency_key)
    )
  end

  def authority_args(idempotency_key)
    {
      authority_identity: "alice",
      expected_policy_fingerprint: @authority.fingerprint("alice"),
      idempotency_key: idempotency_key, provenance: provenance
    }
  end

  def source_id(value)
    "pse-#{Digest::SHA256.hexdigest("source-#{value}")}"
  end

  def evidence
    {
      "label" => "benchmark", "content" => "score", "visibility" => "project",
      "retention" => "project", "media_type" => "text/plain"
    }
  end

  def author
    { "id" => "alice", "kind" => "proposer", "binding" => "team:skills" }
  end

  def policy
    {
      "visibility" => "project", "retention" => "project",
      "allowed_link_schemes" => [ "https" ]
    }
  end

  def provenance
    {
      "task_id" => "43059", "task_generation" => 1,
      "ownership_generation" => "owner-1", "attempt_id" => "attempt-1",
      "workflow_id" => "coding", "stage" => "4-execute",
      "actor" => { "id" => "alice", "kind" => "operator" },
      "source_commit" => "a" * 40
    }
  end
end
