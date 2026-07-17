require "test_helper"
require "hive/babysitter/job_store"

class BabysitterJobStoreTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 17, 14, 0, 0)

  def test_reservation_is_stable_inactive_and_unclaimable_until_journal_handoff
    with_store do |store, task_folder|
      first = reserve(store, task_folder)
      replay = reserve(store, task_folder, finalize_attempt_id: "attempt-2")

      assert_equal first.fetch("job_id"), replay.fetch("job_id")
      assert_equal "inactive", replay.fetch("state")
      assert_nil store.claim!(first.fetch("job_id"), owner: "daemon-a", now: T0)

      write_handoff(task_folder, first)
      active = store.activate!(
        first.fetch("job_id"), handoff_event_id: "finalized", finalize_attempt_id: "attempt-1", now: T0
      )
      assert_equal "active", active.fetch("state")
      assert_equal first.fetch("job_id"), store.current_job(task_slug: "durable-task", task_generation: 3).fetch("job_id")
    end
  end

  def test_startup_repair_activates_a_journal_backed_reservation
    with_store do |store, task_folder|
      job = reserve(store, task_folder)
      write_handoff(task_folder, job)

      repaired = store.repair_activations!(now: T0)

      assert_equal [ job.fetch("job_id") ], repaired.map { |entry| entry.fetch("job_id") }
      assert_equal "active", store.read(job.fetch("job_id")).fetch("state")
    end
  end

  def test_claim_takeover_advances_fence_and_rejects_late_owner
    with_store do |store, task_folder|
      job = activate(store, task_folder)
      first = store.claim!(job.fetch("job_id"), owner: "daemon-a", now: T0, lease_sec: 30)
      assert_equal 1, first.fetch("claim_fence")
      assert_nil store.claim!(job.fetch("job_id"), owner: "daemon-b", now: T0 + 10)

      second = store.claim!(
        job.fetch("job_id"), owner: "daemon-b", now: T0 + 31, lease_sec: 30,
        claim_resolver: ->(_claim) { :resolved }
      )
      assert_equal 2, second.fetch("claim_fence")
      assert_raises(Hive::Babysitter::JobStore::StaleClaim) do
        store.authorize!(first, expected_sha: "a" * 40, head_generation: 1, now: T0 + 32)
      end
      assert store.authorize!(second, expected_sha: "a" * 40, head_generation: 1, now: T0 + 32)
    end
  end

  def test_replacement_requires_exact_closed_or_invalid_proof_and_preserves_history
    with_store do |store, task_folder|
      old = activate(store, task_folder)
      assert_raises(Hive::Babysitter::JobStore::ReplacementBlocked) do
        reserve(store, task_folder, pr_number: 13, replace: old, remote_state: "OPEN")
      end

      replacement = reserve(store, task_folder, pr_number: 13, replace: old, remote_state: "CLOSED")

      assert_equal "superseded", store.read(old.fetch("job_id")).fetch("state")
      assert_equal "inactive", replacement.fetch("state")
      assert_equal old.fetch("job_id"), replacement.fetch("supersedes_job_id")
      assert_equal replacement.fetch("job_id"),
                   store.current_job(task_slug: "durable-task", task_generation: 3).fetch("job_id")
    end
  end

  def test_corrupt_and_truncated_records_fail_closed_without_rewrite
    with_store do |store, task_folder|
      job = reserve(store, task_folder)
      path = store.job_path(job.fetch("job_id"))
      File.binwrite(path, "{")
      before = File.binread(path)

      assert_raises(Hive::Babysitter::JobStore::CorruptRecord) { store.read(job.fetch("job_id")) }
      assert_equal before, File.binread(path)
    end
  end

  def test_journal_writer_rejects_a_stale_claim_fence
    with_store do |store, task_folder|
      job = activate(store, task_folder)
      first = store.claim!(job.fetch("job_id"), owner: "daemon-a", now: T0, lease_sec: 30)
      store.claim!(
        job.fetch("job_id"), owner: "daemon-b", now: T0 + 31, lease_sec: 30,
        claim_resolver: ->(_claim) { :resolved }
      )
      writer = Hive::TaskJournal::Writer.new(
        task_folder: task_folder, authority_validator: store, clock: -> { T0 + 32 }
      )
      coordinates = {
        "job_id" => job.fetch("job_id"), "repository" => "github.com/acme/demo",
        "pr_number" => 12, "pr_url" => "https://github.com/acme/demo/pull/12",
        "head_sha" => "a" * 40, "head_generation" => 1,
        "finalize_attempt_id" => "attempt-1"
      }
      error = assert_raises(Hive::TaskJournal::AttemptMismatch) do
        writer.append_once(
          event_id: "stale-active", event_type: "babysitter_active", occurred_at: (T0 + 32).iso8601(6),
          observed_at: (T0 + 32).iso8601(6), task: { "id" => "42", "slug" => "durable-task" },
          workflow: "coding", stage: "8-finalize", attempt_id: "attempt-1", task_generation: 3,
          ownership_generation: "owner-1", reason: "claimed", evidence: [],
          provenance: { "source" => "test" },
          producer: { "kind" => "babysitter_job", "job_id" => job.fetch("job_id"),
                      "claim_fence" => first.fetch("claim_fence") }, payload: coordinates
        )
      end
      assert_includes error.message, "stale"
    end
  end

  def test_reserve_and_replacement_reject_conflicting_current_coordinates
    with_store do |store, task_folder|
      old = reserve(store, task_folder)
      assert_raises(Hive::Babysitter::JobStore::ReplacementBlocked) do
        reserve(store, task_folder, pr_number: 13)
      end
      assert_raises(Hive::Babysitter::JobStore::ReplacementBlocked) do
        store.reserve_replacement!(
          old_job_id: old.fetch("job_id"), remote_state: "CLOSED", remote_observed_at: T0.iso8601,
          project: "demo", task_id: 42, task_slug: "other-task", task_generation: 3,
          repository: "github.com/acme/demo", pr_number: 13,
          pr_url: "https://github.com/acme/demo/pull/13", branch: "feature/durable",
          head_sha: "a" * 40, head_generation: 1, finalize_attempt_id: "attempt-1",
          task_folder: task_folder, now: T0
        )
      end
      assert_raises(Hive::Babysitter::JobStore::ReplacementBlocked) do
        store.reserve_replacement!(
          old_job_id: old.fetch("job_id"), remote_state: "CLOSED", remote_observed_at: "not-time",
          project: "demo", task_id: 42, task_slug: "durable-task", task_generation: 3,
          repository: "github.com/acme/demo", pr_number: 13,
          pr_url: "https://github.com/acme/demo/pull/13", branch: "feature/durable",
          head_sha: "a" * 40, head_generation: 1, finalize_attempt_id: "attempt-1",
          task_folder: task_folder, now: T0
        )
      end

      replacement = reserve(store, task_folder, pr_number: 13, replace: old, remote_state: "CLOSED")
      assert_raises(Hive::Babysitter::JobStore::ReplacementBlocked) do
        reserve(store, task_folder, pr_number: 14, replace: old, remote_state: "CLOSED")
      end
      assert_equal replacement.fetch("job_id"),
                   store.current_job(task_slug: "durable-task", task_generation: 3).fetch("job_id")
    end
  end

  def test_activation_is_idempotent_only_for_the_same_handoff
    with_store do |store, task_folder|
      job = activate(store, task_folder)
      replay = store.activate!(job.fetch("job_id"), handoff_event_id: "finalized",
                               finalize_attempt_id: "attempt-1", now: T0)
      assert_equal "active", replay.fetch("state")
      assert_raises(Hive::Babysitter::JobStore::InconsistentRecord) do
        store.activate!(job.fetch("job_id"), handoff_event_id: "other",
                        finalize_attempt_id: "attempt-2", now: T0)
      end

      token = store.claim!(job.fetch("job_id"), owner: "daemon", now: T0)
      store.mark_terminal!(token, now: T0)
      assert_raises(Hive::Babysitter::JobStore::InconsistentRecord) do
        store.activate!(job.fetch("job_id"), handoff_event_id: "finalized",
                        finalize_attempt_id: "attempt-1", now: T0)
      end
    end
  end

  def test_activation_requires_the_matching_authoritative_handoff
    with_store do |store, task_folder|
      job = reserve(store, task_folder)

      assert_raises(Hive::Babysitter::JobStore::InconsistentRecord) do
        store.activate!(job.fetch("job_id"), handoff_event_id: "missing",
                        finalize_attempt_id: "attempt-1", now: T0)
      end
    end
  end

  def test_claim_renewal_and_every_authorization_fence_fail_closed
    with_store do |store, task_folder|
      job = activate(store, task_folder)
      token = store.claim!(job.fetch("job_id"), owner: "daemon", now: T0, lease_sec: 30)
      renewed = store.renew!(token, now: T0 + 5, lease_sec: 40)
      assert_equal (T0 + 45).iso8601(6), renewed.fetch("claims").last.fetch("expires_at")

      assert_raises(Hive::Babysitter::JobStore::StaleClaim) do
        store.authorize!(token, expected_sha: "a" * 40, head_generation: 2, now: T0 + 6)
      end
      assert_raises(Hive::Babysitter::JobStore::StaleClaim) do
        store.authorize!(token, expected_sha: "a" * 40, head_generation: 1,
                         finalize_attempt_id: "other", now: T0 + 6)
      end
      assert_raises(Hive::Babysitter::JobStore::StaleClaim) do
        store.authorize!(token, expected_sha: "a" * 40, head_generation: 1, now: T0 + 46)
      end
      assert_raises(ArgumentError) { store.renew!(token, lease_sec: 0) }
    end
  end

  def test_expired_claim_requires_a_successful_owner_resolution
    with_store do |store, task_folder|
      job = activate(store, task_folder)
      store.claim!(job.fetch("job_id"), owner: "daemon-a", now: T0, lease_sec: 1)

      token = store.claim!(
        job.fetch("job_id"), owner: "daemon-b", now: T0 + 2,
        claim_resolver: ->(_claim) { raise "resolver unavailable" }
      )

      assert_nil token
    end
  end

  def test_event_authority_and_head_advancement_require_complete_current_coordinates
    with_store do |store, task_folder|
      job = activate(store, task_folder)
      token = store.claim!(job.fetch("job_id"), owner: "daemon", now: T0)

      assert_raises(Hive::Babysitter::JobStore::StaleClaim) do
        store.validate_event_authority!({ "producer" => token }, now: T0)
      end
      assert_raises(Hive::Babysitter::JobStore::StaleClaim) do
        store.advance_head!(token, previous_sha: "b" * 40, head_sha: "c" * 40,
                            head_generation: 2, now: T0)
      end

      store.send(:write_current_index, job.fetch("identity"), "bsj-v1-#{'f' * 32}", now: T0)
      assert_raises(Hive::Babysitter::JobStore::StaleClaim) do
        store.authorize!(token, expected_sha: "a" * 40, head_generation: 1, now: T0)
      end
    end
  end

  def test_operator_retirement_and_rearm_fence_live_and_expired_claims
    with_store do |store, task_folder|
      job = activate(store, task_folder)
      token = store.claim!(job.fetch("job_id"), owner: "daemon", now: T0, lease_sec: 30)
      write_operator_event(task_folder, job, "no_pr_approved", "approval")

      assert_raises(Hive::Babysitter::JobStore::StaleClaim) do
        store.retire_after_no_pr_approval!(job.fetch("job_id"), approval_event_id: "approval", now: T0)
      end
      retired = store.retire_after_no_pr_approval!(
        job.fetch("job_id"), approval_event_id: "approval", now: T0 + 31
      )
      assert_equal "operator_terminal_approval", retired.fetch("claims").last.fetch("outcome")

      write_operator_event(task_folder, job, "finalization_rearmed", "rearm")
      rearmed = store.rearm_after_approval!(job.fetch("job_id"), rearm_event_id: "rearm", now: T0 + 31)
      assert_equal "active", rearmed.fetch("state")

      fresh = store.claim!(job.fetch("job_id"), owner: "daemon-2", now: T0 + 31, lease_sec: 30)
      assert_raises(Hive::Babysitter::JobStore::StaleClaim) do
        store.rearm_after_approval!(job.fetch("job_id"), rearm_event_id: "rearm", now: T0 + 32)
      end
      repaired = store.rearm_after_approval!(job.fetch("job_id"), rearm_event_id: "rearm", now: T0 + 62)
      assert_equal "operator_rearm_repair", repaired.fetch("claims").last.fetch("outcome")
      refute_nil token
      refute_nil fresh
    end
  end

  def test_operator_transitions_reject_missing_events_bad_states_and_corrupt_claims
    with_store do |store, task_folder|
      inactive = reserve(store, task_folder)
      assert_raises(Hive::Babysitter::JobStore::InconsistentRecord) do
        store.retire_after_no_pr_approval!(inactive.fetch("job_id"), approval_event_id: "missing", now: T0)
      end

      write_operator_event(task_folder, inactive, "finalization_rearmed", "rearm")
      assert_raises(Hive::Babysitter::JobStore::InconsistentRecord) do
        store.rearm_after_approval!(inactive.fetch("job_id"), rearm_event_id: "rearm", now: T0)
      end

      active = activate(store, task_folder)
      with_replaced_singleton_method(store, :verify_operator_event!, lambda { |_record, _id, _type|
        raise ArgumentError, "bad operator evidence"
      }) do
        assert_raises(Hive::Babysitter::JobStore::InconsistentRecord) do
          store.retire_after_no_pr_approval!(active.fetch("job_id"), approval_event_id: "approval", now: T0)
        end
        assert_raises(Hive::Babysitter::JobStore::InconsistentRecord) do
          store.rearm_after_approval!(active.fetch("job_id"), rearm_event_id: "rearm", now: T0)
        end
      end
    end
  end

  def test_strict_reads_paths_folders_and_indexes_report_corruption
    with_store do |store, task_folder|
      job = reserve(store, task_folder)
      path = store.job_path(job.fetch("job_id"))
      data = JSON.parse(File.read(path))
      File.write(path, JSON.generate(data.merge("schema_version" => 99)))
      assert_raises(Hive::Babysitter::JobStore::UnsupportedVersion) { store.read(job.fetch("job_id")) }
      File.write(path, JSON.generate(data))
      assert_raises(Hive::Babysitter::JobStore::RecordNotFound) { store.read("bsj-v1-#{'e' * 32}") }
      assert_raises(Hive::Babysitter::JobStore::RecordNotFound) { store.job_path("../bad") }
      assert_raises(Hive::Babysitter::JobStore::InconsistentRecord) do
        store.reserve!(
          project: "demo", task_id: 43, task_slug: "missing-task", task_generation: 3,
          repository: "github.com/acme/demo", pr_number: 13,
          pr_url: "https://github.com/acme/demo/pull/13", branch: "feature/missing",
          head_sha: "a" * 40, head_generation: 1, finalize_attempt_id: "attempt-1",
          task_folder: File.join(task_folder, "missing"), now: T0
        )
      end
    end

    with_store do |store, task_folder|
      job = reserve(store, task_folder)
      identity = job.fetch("identity")
      index_path = store.send(:current_path, identity)
      File.write(index_path, JSON.generate("schema" => "wrong"))
      assert_raises(Hive::Babysitter::JobStore::CorruptRecord) do
        store.send(:read_current_index, identity, rebuild: false)
      end
      File.write(index_path, "{")
      assert_raises(Hive::Babysitter::JobStore::CorruptRecord) do
        store.send(:read_current_index, identity, rebuild: false)
      end
      FileUtils.rm_f(index_path)
      assert_equal job.fetch("job_id"),
                   store.current_job(task_slug: "durable-task", task_generation: 3).fetch("job_id")
    end
  end

  private

  def with_store
    with_tmp_dir do |project|
      task_folder = File.join(project, ".hive-state", "stages", "8-finalize", "durable-task")
      FileUtils.mkdir_p(task_folder)
      yield Hive::Babysitter::JobStore.new(project_root: project, clock: -> { T0 + 32 }), task_folder
    end
  end

  def reserve(store, task_folder, finalize_attempt_id: "attempt-1", pr_number: 12,
              replace: nil, remote_state: nil)
    attributes = {
      project: "demo", task_id: 42, task_slug: "durable-task", task_generation: 3,
      repository: "https://github.com/acme/demo", pr_number: pr_number,
      pr_url: "https://github.com/acme/demo/pull/#{pr_number}", branch: "feature/durable",
      head_sha: "a" * 40, head_generation: 1, finalize_attempt_id: finalize_attempt_id,
      task_folder: task_folder, now: T0
    }
    return store.reserve!(**attributes) unless replace

    store.reserve_replacement!(
      old_job_id: replace.fetch("job_id"), remote_state: remote_state,
      remote_observed_at: T0.iso8601, **attributes
    )
  end

  def activate(store, task_folder)
    job = reserve(store, task_folder)
    write_handoff(task_folder, job)
    store.activate!(job.fetch("job_id"), handoff_event_id: "finalized",
                    finalize_attempt_id: "attempt-1", now: T0)
  end

  def write_handoff(task_folder, job)
    payload = {
      "job_id" => job.fetch("job_id"), "repository" => "github.com/acme/demo",
      "pr_number" => 12, "pr_url" => "https://github.com/acme/demo/pull/12",
      "head_sha" => "a" * 40, "head_generation" => 1,
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

  def write_operator_event(task_folder, job, event_type, event_id)
    identity = job.fetch("identity")
    payload = {
      "job_id" => job.fetch("job_id"), "repository" => identity.fetch("repository"),
      "pr_number" => identity.fetch("pr_number"), "pr_url" => job.fetch("pr_url"),
      "head_sha" => job.fetch("head_sha"), "head_generation" => job.fetch("head_generation"),
      "finalize_attempt_id" => job.fetch("finalize_attempt_id")
    }
    event = Hive::TaskJournal::Envelope.authoritative({
      event_type: event_type, event_id: event_id, occurred_at: T0.iso8601(6),
      observed_at: T0.iso8601(6), task: { "id" => "42", "slug" => "durable-task" },
      workflow: "coding", stage: "8-finalize", attempt_id: job.fetch("finalize_attempt_id"),
      task_generation: identity.fetch("task_generation"), ownership_generation: "operator-1",
      reason: "operator transition", evidence: [], provenance: { "source" => "test" },
      producer: { "kind" => "operator", "uid" => 1, "login" => "tester", "channel" => "local_tty" },
      payload: payload
    })
    File.open(File.join(task_folder, "events.jsonl"), "a") { |file| file.puts(JSON.generate(event)) }
  end
end
