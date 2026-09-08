require "test_helper"
require "hive/proposals/decision_service"

class ProposalDecisionServiceTest < Minitest::Test
  include HiveTestHelper

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
      outcome: "accepted", considered_evaluations: observations(first),
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
      outcome: "accepted", considered_evaluations: observations(first),
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

  def test_changed_considered_evaluation_digest_is_stale
    evaluation = append_evaluation(proposal_id, source: "b", outcome: "pass", metric: 0.91)
    considered = observations(evaluation)
    path = @store.path_for_event(evaluation)
    rewritten = JSON.parse(File.read(path))
    rewritten.dig("data", "result", "metrics")["recall"] = 0.5
    File.write(path, Hive::Proposals.canonical(rewritten))

    assert_raises(Hive::Proposals::StaleObservation) do
      decide(
        outcome: "accepted", considered_evaluations: considered,
        expected_head: @store.projection(proposal_id).lifecycle_head,
        idempotency_key: "rewritten-evaluation"
      )
    end
  end

  def test_missing_considered_evaluation_is_stale
    missing = "pev-00000000-0000-4000-8000-000000000099"

    assert_raises(Hive::Proposals::StaleObservation) do
      decide(
        outcome: "accepted",
        considered_evaluations: [ { "evaluation_id" => missing, "result_digest" => "a" * 64 } ],
        expected_head: @store.projection(proposal_id).lifecycle_head,
        idempotency_key: "missing-evaluation"
      )
    end
  end

  def test_terminal_retry_is_a_noop_and_conflicting_decisions_are_refused
    evaluation = append_evaluation(proposal_id, source: "b", outcome: "pass", metric: 0.91)
    observation = @store.projection(proposal_id).lifecycle_head
    first = decide(
      outcome: "accepted", considered_evaluations: observations(evaluation),
      expected_head: observation, idempotency_key: "same-source"
    )
    replay = decide(
      outcome: "accepted", considered_evaluations: observations(evaluation),
      expected_head: observation, idempotency_key: "same-source"
    )

    assert first.applied
    refute replay.applied
    assert_equal first.event.event_id, replay.event.event_id
    assert_raises(Hive::Proposals::Conflict) do
      decide(
        outcome: "rejected", considered_evaluations: observations(evaluation),
        expected_head: observation, idempotency_key: "other-source"
      )
    end
  end

  def test_unevaluated_rejection_requires_the_closed_no_evaluation_category
    head = @store.projection(proposal_id).lifecycle_head
    assert_raises(Hive::Proposals::InvalidEvent) do
      decide(
        outcome: "accepted", considered_evaluations: [], expected_head: head,
        idempotency_key: "unevaluated-accept", rationale_category: "evaluated"
      )
    end

    result = decide(
      outcome: "rejected", considered_evaluations: [], expected_head: head,
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
      considered_evaluations: observations(evaluation), rationale_category: "evaluated",
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
        outcome: "accepted", considered_evaluations: observations(evaluation, evaluation),
        expected_head: head, idempotency_key: "duplicate-evidence"
      )
    end

    decide(
      outcome: "accepted", considered_evaluations: observations(evaluation),
      expected_head: head, idempotency_key: "immutable-decision"
    )
    assert_raises(Hive::Proposals::Conflict) do
      @service.decide(
        proposal_id:, outcome: "accepted", considered_evaluations: observations(evaluation),
        rationale_category: "evaluated", rationale: "changed rationale", links: [],
        expected_head: head, **authority_args("immutable-decision")
      )
    end

    assert_raises(Hive::Proposals::InvalidRecord) do
      @service.decide(
        proposal_id: "prp-00000000-0000-4000-8000-000000000099", outcome: "rejected",
        considered_evaluations: [], rationale_category: "no_evaluation", rationale: "missing",
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
      proposal_id:, outcome: "accepted", considered_evaluations: observations(evaluation),
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
        proposal_id:, outcome: "accepted", considered_evaluations: observations(evaluation),
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
          outcome:, considered_evaluations: observations(evaluation),
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

  def test_lifecycle_commit_is_durable_exact_and_preserves_unrelated_staging
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      root = File.join(ops.hive_state_path, "proposals", "v1")
      store = decision_store(root)
      with_store(store) do
        create_record(proposal_id)
        evaluation = append_evaluation(proposal_id, source: "b", outcome: "pass", metric: 0.91)
        seed_proposal_history(ops, store, proposal_id, evaluation)
        unrelated = "stages/1-inbox/unrelated/prestaged.txt"
        FileUtils.mkdir_p(File.dirname(File.join(ops.hive_state_path, unrelated)))
        File.write(File.join(ops.hive_state_path, unrelated), "preserve me\n")
        run!("git", "-C", ops.hive_state_path, "add", unrelated)
        service = durable_service(store, ops)

        result = service.decide(
          proposal_id:, outcome: "accepted", considered_evaluations: observations(evaluation),
          rationale_category: "evaluated", rationale: "accept", links: [],
          expected_head: store.projection(proposal_id).lifecycle_head,
          **authority_args("committed-lifecycle")
        )

        event_path = store.path_for_event(result.event).delete_prefix("#{ops.hive_state_path}/")
        changed = run!(
          "git", "-C", ops.hive_state_path, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"
        ).lines.map(&:strip)
        assert_equal [ event_path, "proposals/v1/inbox/index.json" ].sort, changed.sort
        assert_equal "A  #{unrelated}", run!(
          "git", "-C", ops.hive_state_path, "status", "--porcelain=v1", "--", unrelated
        ).strip
        assert_equal Hive::Proposals.canonical(result.event.to_h),
                     ops.read_hive_state_blob_at(
                       ops.hive_state_head_sha, event_path,
                       max_bytes: Hive::Proposals::Store::MAX_FILE_BYTES + 1
                     )
      end
    end
  end

  def test_lifecycle_commit_and_index_restore_failures_are_visible
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      root = File.join(ops.hive_state_path, "proposals", "v1")
      store = decision_store(root)
      with_store(store) do
        create_record(proposal_id)
        evaluation = append_evaluation(proposal_id, source: "h", outcome: "pass", metric: 0.9)
        seed_proposal_history(ops, store, proposal_id, evaluation)
        original_commit = ops.method(:hive_commit)
        ops.define_singleton_method(:hive_commit) do |**options|
          original_commit.call(
            **options.merge(after_stage: -> { raise Hive::GitError, "simulated lifecycle commit failure" })
          )
        end
        service = durable_service(store, ops)

        assert_raises(Hive::GitError) do
          service.decide(
            proposal_id:, outcome: "accepted", considered_evaluations: observations(evaluation),
            rationale_category: "evaluated", rationale: "accept", links: [],
            expected_head: store.projection(proposal_id).lifecycle_head,
            **authority_args("failed-lifecycle")
          )
        end
        assert_equal [ "evaluation" ], store.projection(proposal_id).events.map(&:type)

        unrelated = "stages/1-inbox/unrelated/prestaged.txt"
        FileUtils.mkdir_p(File.dirname(File.join(ops.hive_state_path, unrelated)))
        File.write(File.join(ops.hive_state_path, unrelated), "preserve me\n")
        run!("git", "-C", ops.hive_state_path, "add", unrelated)
        original_run_git = ops.method(:run_git!)
        ops.define_singleton_method(:run_git!) do |*arguments|
          if arguments.include?("read-tree")
            raise Hive::GitError, "simulated index restore failure"
          end
          original_run_git.call(*arguments)
        end

        error = assert_raises(Hive::GitError) do
          service.decide(
            proposal_id:, outcome: "accepted", considered_evaluations: observations(evaluation),
            rationale_category: "evaluated", rationale: "accept", links: [],
            expected_head: store.projection(proposal_id).lifecycle_head,
            **authority_args("failed-restore")
          )
        end
        assert_includes error.message, "index restore failure"
      end
    end
  end

  def test_lifecycle_rejects_commit_results_without_a_new_durable_head
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      root = File.join(ops.hive_state_path, "proposals", "v1")
      store = decision_store(root)
      with_store(store) do
        create_record(proposal_id)
        evaluation = append_evaluation(proposal_id, source: "j", outcome: "pass", metric: 0.9)
        seed_proposal_history(ops, store, proposal_id, evaluation)
        service = durable_service(store, ops)

        %i[nothing_to_commit committed].each do |commit_result|
          ops.define_singleton_method(:hive_commit) { |**_options| commit_result }
          assert_raises(Hive::Proposals::SourceUnavailable) do
            service.decide(
              proposal_id:, outcome: "accepted", considered_evaluations: observations(evaluation),
              rationale_category: "evaluated", rationale: "accept", links: [],
              expected_head: store.projection(proposal_id).lifecycle_head,
              **authority_args("undurable-#{commit_result}")
            )
          end
          assert_equal [ "evaluation" ], store.projection(proposal_id).events.map(&:type)
        end
      end
    end
  end

  def test_lifecycle_mutations_obey_namespace_event_and_authority_rate_limits
    event_limited = Hive::Proposals::DecisionService.new(
      store: @store, authority: @authority,
      limits: { "max_project_events" => 1 },
      clock: -> { Time.utc(2026, 8, 30, 12, 30, 0) }
    )
    assert_raises(Hive::Proposals::QuotaExceeded) do
      event_limited.decide(
        proposal_id:, outcome: "rejected", considered_evaluations: [],
        rationale_category: "no_evaluation", rationale: "reject", links: [],
        expected_head: @store.projection(proposal_id).lifecycle_head,
        **authority_args("event-limited")
      )
    end

    first = decide(
      outcome: "rejected", considered_evaluations: [],
      expected_head: @store.projection(proposal_id).lifecycle_head,
      idempotency_key: "first-authority-event", rationale_category: "no_evaluation"
    )
    refute_nil first.event
    second_id = "prp-00000000-0000-4000-8000-000000000008"
    create_record(second_id)
    rate_limited = Hive::Proposals::DecisionService.new(
      store: @store, authority: @authority,
      limits: { "max_sources_per_actor_per_hour" => 1 },
      clock: -> { Time.utc(2026, 8, 30, 12, 30, 0) }
    )
    assert_raises(Hive::Proposals::QuotaExceeded) do
      rate_limited.decide(
        proposal_id: second_id, outcome: "rejected", considered_evaluations: [],
        rationale_category: "no_evaluation", rationale: "reject", links: [],
        expected_head: @store.projection(second_id).lifecycle_head,
        **authority_args("rate-limited")
      )
    end
  end

  private

  def proposal_id = "prp-00000000-0000-4000-8000-000000000001"

  def decision_store(root)
    Hive::Proposals::Store.new(
      root:,
      id_generator: lambda do
        @id_mutex.synchronize do
          @next_id += 1
          format("00000000-0000-4000-8000-%012d", @next_id)
        end
      end
    )
  end

  def with_store(store)
    previous = @store
    @store = store
    yield
  ensure
    @store = previous
  end

  def seed_proposal_history(ops, store, id, evaluation)
    ops.hive_commit(
      stage_name: "proposals", slug: id, action: "seeded lifecycle history",
      pathspecs: [
        store.paths_for_record(id).first.delete_prefix("#{ops.hive_state_path}/"),
        store.path_for_event(evaluation).delete_prefix("#{ops.hive_state_path}/")
      ]
    )
  end

  def durable_service(store, ops)
    Hive::Proposals::DecisionService.new(
      store:, authority: @authority, git_ops: ops,
      clock: -> { Time.utc(2026, 8, 30, 12, 30, 0) }
    )
  end

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

  def decide(outcome:, considered_evaluations:, expected_head:, idempotency_key:,
             rationale_category: "evaluated")
    @service.decide(
      proposal_id:, outcome:, considered_evaluations:, rationale_category:,
      rationale: "lifecycle decision", links: [], expected_head:,
      **authority_args(idempotency_key)
    )
  end

  def observations(*evaluations)
    evaluations.map do |evaluation|
      {
        "evaluation_id" => evaluation.event_id,
        "result_digest" => Hive::Proposals.digest(evaluation.data.fetch("result"))
      }
    end
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
