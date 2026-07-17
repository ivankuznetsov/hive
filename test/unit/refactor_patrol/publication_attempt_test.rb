require "test_helper"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/publication_attempt"

class RefactorPatrolPublicationAttemptTest < Minitest::Test
  include HiveTestHelper

  Publication = Hive::RefactorPatrol::PublicationAttempt
  JobStore = Hive::RefactorPatrol::JobStore
  T0 = Time.utc(2026, 7, 12, 12, 0, 0)
  BASE = ("a" * 40).freeze
  COMMIT = ("b" * 40).freeze
  DRIFTED_BASE = ("c" * 40).freeze

  def test_ensure_for_patch_validates_patch_identity_and_attempt_container
    [ nil, {}, { "publication_base_sha" => BASE },
      { "publication_base_sha" => BASE, "commit_sha" => 7 } ].each do |invalid|
      assert_publication_error("publication patch receipt has invalid identity") do
        Publication.ensure_for_patch(receipts: {}, patch_receipt: invalid, recorded_at: T0.iso8601)
      end
    end

    assert_publication_error("publication patch receipt has invalid identity") do
      Publication.ensure_for_patch(receipts: [], patch_receipt: patch, recorded_at: T0.iso8601)
    end
    assert_publication_error("publication attempts receipt is invalid") do
      Publication.ensure_for_patch(
        receipts: { Publication::ATTEMPTS_KEY => [] },
        patch_receipt: patch,
        recorded_at: T0.iso8601
      )
    end
  end

  def test_ensure_for_patch_is_idempotent_and_rejects_identity_changes
    state = publication_state
    assert_equal state, Publication.ensure_for_patch(
      receipts: state,
      patch_receipt: patch,
      recorded_at: (T0 + 1).iso8601
    )

    malformed = copy(state)
    malformed.dig(Publication::ATTEMPTS_KEY, attempt_id)["descriptor"] = "invalid"
    assert_publication_error("publication attempt identity is immutable") do
      Publication.ensure_for_patch(
        receipts: malformed, patch_receipt: patch, recorded_at: (T0 + 1).iso8601
      )
    end

    malformed_attempt = copy(state)
    malformed_attempt.fetch(Publication::ATTEMPTS_KEY)[attempt_id] = "invalid"
    assert_publication_error("publication attempt identity is immutable") do
      Publication.ensure_for_patch(
        receipts: malformed_attempt, patch_receipt: patch, recorded_at: (T0 + 1).iso8601
      )
    end

    mismatched = copy(state)
    mismatched.dig(Publication::ATTEMPTS_KEY, attempt_id, "descriptor")["patch_receipt_key"] = "patch_2"
    assert_publication_error("publication attempt identity is immutable") do
      Publication.ensure_for_patch(
        receipts: mismatched, patch_receipt: patch, recorded_at: (T0 + 1).iso8601
      )
    end

    missing_patch = copy(state).tap { |value| value.delete("patch") }
    assert_publication_error("publication attempt identity is immutable") do
      Publication.ensure_for_patch(
        receipts: missing_patch, patch_receipt: patch, recorded_at: (T0 + 1).iso8601
      )
    end
  end

  def test_ensure_for_patch_serializes_active_replacements_and_revoked_claims
    active = publication_state
    replacement = patch(base: DRIFTED_BASE, commit: "d" * 40)
    assert_publication_error("another publication attempt is still active") do
      Publication.ensure_for_patch(
        receipts: active, patch_receipt: replacement, recorded_at: (T0 + 1).iso8601
      )
    end

    assert_publication_error("revoked action claim cannot record a replacement patch") do
      Publication.ensure_for_patch(
        receipts: {}, patch_receipt: patch, recorded_at: T0.iso8601, continuation_only: true
      )
    end

    preexisting_patch = { "patch" => patch }
    resumed = Publication.ensure_for_patch(
      receipts: preexisting_patch,
      patch_receipt: patch,
      recorded_at: T0.iso8601,
      continuation_only: true
    )
    assert_equal "patch", resumed.dig(Publication::ATTEMPTS_KEY, attempt_id, "descriptor", "patch_receipt_key")
  end

  def test_ensure_for_patch_allocates_after_numbered_and_legacy_patch_keys
    patch_2 = patch(base: "d" * 40, commit: "e" * 40)
    state = Publication.ensure_for_patch(
      receipts: { "patch_2" => patch_2, Publication::ATTEMPTS_KEY => {} },
      patch_receipt: patch,
      recorded_at: T0.iso8601
    )
    assert_equal patch, state.fetch("patch_3")

    replacement = patch(base: DRIFTED_BASE, commit: "f" * 40)
    state = Publication.ensure_for_patch(
      receipts: { "patch" => patch, Publication::ATTEMPTS_KEY => {} },
      patch_receipt: replacement,
      recorded_at: T0.iso8601
    )
    assert_equal replacement, state.fetch("patch_2")
  end

  def test_append_phase_validates_identity_presence_and_supersession
    [ [ "bad-id", "push_intent", phase_payload ],
      [ attempt_id, "unknown", phase_payload ],
      [ attempt_id, "push_intent", {} ],
      [ attempt_id, "push_intent", "invalid" ] ].each do |id, phase, payload|
      assert_publication_error("publication attempt phase is invalid") do
        Publication.append_phase(
          receipts: publication_state, attempt_id: id, phase: phase, payload: payload
        )
      end
    end

    assert_publication_error("publication attempt is missing") do
      Publication.append_phase(
        receipts: { Publication::ATTEMPTS_KEY => {} },
        attempt_id: attempt_id,
        phase: "push_intent",
        payload: phase_payload
      )
    end

    superseded = Publication.supersede(
      receipts: publication_state,
      attempt_id: attempt_id,
      observed_head_sha: DRIFTED_BASE,
      recorded_at: (T0 + 1).iso8601
    )
    assert_publication_error("superseded publication attempt cannot advance") do
      Publication.append_phase(
        receipts: superseded,
        attempt_id: attempt_id,
        phase: "push_intent",
        payload: phase_payload
      )
    end
  end

  def test_append_phase_is_idempotent_but_phase_values_are_immutable
    state = Publication.append_phase(
      receipts: publication_state,
      attempt_id: attempt_id,
      phase: "push_intent",
      payload: phase_payload
    )
    assert_equal state, Publication.append_phase(
      receipts: state,
      attempt_id: attempt_id,
      phase: "push_intent",
      payload: phase_payload
    )

    assert_publication_error("publication attempt phase is immutable") do
      Publication.append_phase(
        receipts: state,
        attempt_id: attempt_id,
        phase: "push_intent",
        payload: { "operation" => "changed" }
      )
    end
  end

  def test_append_phase_enforces_continuation_and_phase_order
    assert_publication_error("revoked action claim cannot begin a publication phase") do
      Publication.append_phase(
        receipts: publication_state,
        attempt_id: attempt_id,
        phase: "push_intent",
        payload: phase_payload,
        continuation_only: true
      )
    end

    with_intent = Publication.append_phase(
      receipts: publication_state,
      attempt_id: attempt_id,
      phase: "push_intent",
      payload: phase_payload
    )
    reconciled = Publication.append_phase(
      receipts: with_intent,
      attempt_id: attempt_id,
      phase: "push_complete",
      payload: { "operation" => "push_branch_complete" },
      continuation_only: true
    )
    assert_equal "push_branch_complete",
                 reconciled.dig(Publication::ATTEMPTS_KEY, attempt_id, "push_complete", "operation")
    assert_publication_error("revoked action claim cannot begin a publication phase") do
      Publication.append_phase(
        receipts: reconciled,
        attempt_id: attempt_id,
        phase: "pr_create_intent",
        payload: { "operation" => "create_pr" },
        continuation_only: true
      )
    end

    assert_phase_order_error(
      { "push_complete" => phase_payload },
      phase: "push_intent",
      message: "publication push intent cannot be appended after completion"
    )
    assert_phase_order_error(
      { "pr_create_intent" => phase_payload },
      phase: "push_complete",
      message: "publication push completion cannot follow PR-create intent"
    )
    assert_phase_order_error(
      {},
      phase: "pr_create_intent",
      message: "publication PR-create intent requires durable push completion"
    )
  end

  def test_supersede_validates_evidence_attempt_and_descriptor
    [ [ "bad-id", DRIFTED_BASE ], [ attempt_id, "short" ], [ attempt_id, "z" * 40 ] ].each do |id, observed|
      assert_publication_error("publication supersession evidence is invalid") do
        Publication.supersede(
          receipts: publication_state,
          attempt_id: id,
          observed_head_sha: observed,
          recorded_at: T0.iso8601
        )
      end
    end

    assert_publication_error("publication attempt is missing") do
      Publication.supersede(
        receipts: { Publication::ATTEMPTS_KEY => {} },
        attempt_id: attempt_id,
        observed_head_sha: DRIFTED_BASE,
        recorded_at: T0.iso8601
      )
    end

    [ nil, { "attempt_id" => "f" * 64 } ].each do |descriptor|
      malformed = publication_state
      malformed.dig(Publication::ATTEMPTS_KEY, attempt_id)["descriptor"] = descriptor
      assert_publication_error("publication attempt descriptor is invalid") do
        Publication.supersede(
          receipts: malformed,
          attempt_id: attempt_id,
          observed_head_sha: DRIFTED_BASE,
          recorded_at: T0.iso8601
        )
      end
    end
  end

  def test_supersede_is_idempotent_and_rejects_conflicting_or_post_create_evidence
    superseded = Publication.supersede(
      receipts: publication_state,
      attempt_id: attempt_id,
      observed_head_sha: DRIFTED_BASE,
      recorded_at: T0.iso8601
    )
    assert_equal superseded, Publication.supersede(
      receipts: superseded,
      attempt_id: attempt_id,
      observed_head_sha: DRIFTED_BASE,
      recorded_at: (T0 + 10).iso8601
    )

    [ { "reason" => "other", "observed_head_sha" => DRIFTED_BASE, "recorded_at" => T0.iso8601 },
      "invalid" ].each do |evidence|
      conflicting = copy(superseded)
      conflicting.dig(Publication::ATTEMPTS_KEY, attempt_id)["superseded"] = evidence
      assert_publication_error("publication supersession is immutable") do
        Publication.supersede(
          receipts: conflicting,
          attempt_id: attempt_id,
          observed_head_sha: DRIFTED_BASE,
          recorded_at: T0.iso8601
        )
      end
    end

    assert_publication_error("publication supersession requires observed trunk drift") do
      Publication.supersede(
        receipts: publication_state,
        attempt_id: attempt_id,
        observed_head_sha: BASE,
        recorded_at: T0.iso8601
      )
    end

    post_create = publication_state
    post_create.dig(Publication::ATTEMPTS_KEY, attempt_id)["pr_create_intent"] = phase_payload
    assert_publication_error("post-create publication attempt cannot be superseded") do
      Publication.supersede(
        receipts: post_create,
        attempt_id: attempt_id,
        observed_head_sha: DRIFTED_BASE,
        recorded_at: T0.iso8601
      )
    end
  end

  def test_active_patch_key_validates_cardinality_and_falls_back_to_unreferenced_patches
    assert_publication_error("publication attempts receipt is invalid") do
      Publication.active_patch_key(Publication::ATTEMPTS_KEY => [])
    end

    one = publication_state
    assert_equal "patch", Publication.active_patch_key(one)
    multiple = copy(one)
    multiple.fetch(Publication::ATTEMPTS_KEY)["f" * 64] = copy(
      multiple.dig(Publication::ATTEMPTS_KEY, attempt_id)
    )
    assert_publication_error("multiple publication attempts are active") do
      Publication.active_patch_key(multiple)
    end

    fallback = {
      "patch" => { "commit_sha" => "1" * 40 },
      "patch_2" => { "commit_sha" => "2" * 40 },
      "patch_3" => { "commit_sha" => "3" * 40 },
      Publication::ATTEMPTS_KEY => {
        "old" => {
          "descriptor" => { "patch_receipt_key" => "patch_3" },
          "superseded" => {}
        },
        "malformed" => "ignored"
      },
      "patch_superseded_legacy" => { "commit_sha" => "3" * 40 },
      "patch_superseded_invalid" => "ignored",
      "other" => {}
    }
    assert_equal "patch_2", Publication.active_patch_key(fallback)
    assert_nil Publication.active_patch_key(Publication::ATTEMPTS_KEY => {})
    assert_nil Publication.active_patch_key({})
  end

  def test_state_and_predicate_projections_handle_active_and_terminal_attempts
    state = publication_state
    attempt = state.dig(Publication::ATTEMPTS_KEY, attempt_id)
    attempt["push_intent"] = phase_payload
    attempt["push_complete"] = { "operation" => "push_branch_complete" }
    assert_equal(
      {
        "push_intent" => phase_payload,
        "push_complete" => { "operation" => "push_branch_complete" }
      },
      Publication.state_for(state, attempt_id)
    )
    assert Publication.phase_evidence?(state)
    assert Publication.pre_create?(attempt)
    assert Publication.remote_push_evidence?(attempt)

    empty = publication_state
    assert_equal({}, Publication.state_for(empty, attempt_id))
    refute Publication.phase_evidence?(Publication::ATTEMPTS_KEY => { attempt_id => "invalid" })
    refute Publication.remote_push_evidence?("invalid")

    terminal = copy(state)
    terminal.dig(Publication::ATTEMPTS_KEY, attempt_id)["superseded"] = {}
    assert_nil Publication.state_for(terminal, attempt_id)
    terminal.dig(Publication::ATTEMPTS_KEY, attempt_id)["pr_create_intent"] = phase_payload
    refute Publication.pre_create?(terminal.dig(Publication::ATTEMPTS_KEY, attempt_id))
    refute Publication.pre_create?(nil)
  end

  def test_legacy_phases_copy_only_matching_operations_and_commits
    descriptor = Publication.descriptor(
      patch_receipt_key: "patch",
      publication_base_sha: BASE,
      commit_sha: COMMIT,
      recorded_at: T0.iso8601
    )
    push_intent = { "operation" => "push_branch", "commit_sha" => COMMIT }
    push_complete = { "operation" => "push_branch_complete", "commit_sha" => COMMIT }
    create_intent = { "operation" => "create_pr", "commit_sha" => COMMIT }
    receipts = {
      "creation_intent" => { "payload" => push_intent },
      "push_complete" => push_complete,
      "pr_create_intent" => create_intent
    }
    assert_equal(
      {
        "push_intent" => push_intent,
        "push_complete" => push_complete,
        "pr_create_intent" => create_intent
      },
      Publication.legacy_phases(receipts, descriptor)
    )
    assert_empty Publication.legacy_phases(nil, descriptor)
    assert_empty Publication.legacy_phases(receipts, nil)

    ignored = {
      "creation_intent" => {
        "payload" => { "operation" => "unknown", "commit_sha" => COMMIT }
      },
      "push_complete" => { "operation" => "create_pr", "commit_sha" => COMMIT },
      "pr_create_intent" => { "operation" => "create_pr", "commit_sha" => "d" * 40 }
    }
    assert_empty Publication.legacy_phases(ignored, descriptor)
  end

  def test_superseded_remote_commits_unions_namespaced_and_strict_legacy_proof
    namespaced_commit = "4" * 40
    legacy_commit = "5" * 40
    namespaced_id = Publication.id_for(publication_base_sha: BASE, commit_sha: namespaced_commit)
    namespaced = Publication.build(
      descriptor: Publication.descriptor(
        patch_receipt_key: "patch_2",
        publication_base_sha: BASE,
        commit_sha: namespaced_commit,
        recorded_at: T0.iso8601
      )
    ).merge(
      "push_complete" => { "operation" => "push_branch_complete" },
      "superseded" => { "reason" => "trunk_drift_retry" }
    )
    receipts = valid_legacy_supersession(legacy_commit).merge(
      "patch_2" => { "commit_sha" => namespaced_commit, "branch" => "hive-refactor/current" },
      Publication::ATTEMPTS_KEY => {
        namespaced_id => namespaced,
        "malformed" => "ignored",
        "not-superseded" => { "push_complete" => {} }
      }
    )
    assert_equal [ namespaced_commit, legacy_commit ].sort,
                 Publication.superseded_remote_commits(receipts)

    assert_equal [ legacy_commit ], Publication.superseded_remote_commits(
      valid_legacy_supersession(legacy_commit).merge(Publication::ATTEMPTS_KEY => [])
    )
  end

  def test_superseded_remote_commits_rejects_partial_legacy_shapes
    commit = "6" * 40
    valid = valid_legacy_supersession(commit)
    invalid = []
    invalid << valid.merge("patch" => "invalid")
    invalid << valid.merge("patch_superseded_#{Digest::SHA256.hexdigest(commit)}" => "invalid")
    invalid << copy(valid).tap do |value|
      value.fetch("patch_superseded_#{Digest::SHA256.hexdigest(commit)}")["reason"] = "other"
    end
    invalid << copy(valid).tap { |value| value.fetch("patch").delete("branch") }
    invalid << valid.reject { |key, _| key.start_with?("patch_superseded_") }.merge(
      "patch_superseded_wrong" => { "reason" => "trunk_drift_retry", "commit_sha" => commit }
    )
    invalid << copy(valid).tap { |value| value.fetch("push_complete")["remote_oid"] = "7" * 40 }
    invalid.each { |receipts| assert_empty Publication.superseded_remote_commits(receipts) }
  end

  def test_job_store_wrappers_translate_publication_errors
    store, = wrapper_store({})
    error = assert_raises(JobStore::InconsistentRecord) do
      store.record_patch_publication_attempt!({}, receipt: {}, now: T0)
    end
    assert_equal "publication patch receipt has invalid identity", error.message

    error = assert_raises(JobStore::InconsistentRecord) do
      store.record_publication_attempt_phase!(
        {}, attempt_id: attempt_id, phase: "push_intent", payload: phase_payload, now: T0
      )
    end
    assert_equal "publication attempt is missing", error.message

    error = assert_raises(JobStore::InconsistentRecord) do
      store.supersede_publication_attempt!(
        {}, attempt_id: attempt_id, observed_head_sha: "short", now: T0
      )
    end
    assert_equal "publication supersession evidence is invalid", error.message
  end

  def test_job_store_wrappers_do_not_touch_state_on_idempotent_retries
    creating_store, creating_aggregate, creating_action = wrapper_store({})
    creating_store.record_patch_publication_attempt!({}, receipt: patch, now: T0 + 1)
    assert_equal (T0 + 1).iso8601, creating_aggregate.fetch("updated_at")
    assert_equal patch, creating_action.fetch("receipts").fetch("patch")

    store, aggregate, action = wrapper_store(publication_state)
    store.record_patch_publication_attempt!({}, receipt: patch, now: T0 + 1)
    assert_equal T0.iso8601, aggregate.fetch("updated_at")

    store.record_publication_attempt_phase!(
      {}, attempt_id: attempt_id, phase: "push_intent", payload: phase_payload, now: T0 + 2
    )
    after_phase = copy(action)
    store.record_publication_attempt_phase!(
      {}, attempt_id: attempt_id, phase: "push_intent", payload: phase_payload, now: T0 + 3
    )
    assert_equal after_phase, action

    store.supersede_publication_attempt!(
      {}, attempt_id: attempt_id, observed_head_sha: DRIFTED_BASE, now: T0 + 4
    )
    after_supersession = copy(action)
    store.supersede_publication_attempt!(
      {}, attempt_id: attempt_id, observed_head_sha: DRIFTED_BASE, now: T0 + 5
    )
    assert_equal after_supersession, action
  end

  private

  def patch(base: BASE, commit: COMMIT)
    {
      "branch" => "hive-refactor/fix-action",
      "publication_base_sha" => base,
      "commit_sha" => commit
    }
  end

  def attempt_id(base: BASE, commit: COMMIT)
    Publication.id_for(publication_base_sha: base, commit_sha: commit)
  end

  def publication_state
    Publication.ensure_for_patch(
      receipts: {}, patch_receipt: patch, recorded_at: T0.iso8601
    )
  end

  def phase_payload
    { "operation" => "push_branch", "commit_sha" => COMMIT }
  end

  def assert_phase_order_error(initial_phases, phase:, message:)
    state = publication_state
    state.dig(Publication::ATTEMPTS_KEY, attempt_id).merge!(initial_phases)
    assert_publication_error(message) do
      Publication.append_phase(
        receipts: state,
        attempt_id: attempt_id,
        phase: phase,
        payload: phase_payload
      )
    end
  end

  def valid_legacy_supersession(commit)
    branch = "hive-refactor/legacy"
    {
      "patch" => { "commit_sha" => commit, "branch" => branch },
      "push_complete" => {
        "operation" => "push_branch_complete",
        "commit_sha" => commit,
        "remote_oid" => commit,
        "branch" => branch
      },
      "patch_superseded_#{Digest::SHA256.hexdigest(commit)}" => {
        "reason" => "trunk_drift_retry",
        "commit_sha" => commit
      },
      "other" => {}
    }
  end

  def wrapper_store(receipts)
    aggregate = { "updated_at" => T0.iso8601 }
    action = { "receipts" => copy(receipts), "updated_at" => T0.iso8601 }
    claim = { "authority" => "full" }
    store = JobStore.allocate
    store.define_singleton_method(:mutate_action_claim) do |_token, now:, &block|
      block.call(aggregate, action, claim)
    end
    [ store, aggregate, action ]
  end

  def assert_publication_error(message)
    error = assert_raises(Publication::Error) { yield }
    assert_equal message, error.message
  end

  def copy(value)
    JSON.parse(JSON.generate(value))
  end
end
