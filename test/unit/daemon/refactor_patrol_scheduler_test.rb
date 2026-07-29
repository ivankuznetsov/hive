require "test_helper"
require "json"
require "hive/daemon/refactor_patrol_scheduler"

class HiveDaemonRefactorPatrolSchedulerTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 10, 12, 0, 0)

  class Guard
    def initialize(sha: "head")
      @sha = sha
    end

    def validate_and_snapshot!(merge_sha:, analysis_sha: nil)
      raise "missing merge" if merge_sha.to_s.empty?

      { "analysis_sha" => analysis_sha || @sha }
    end
  end

  def test_reserves_oldest_due_job_with_stable_identity_and_durable_manifest_command
    with_project do |dir, entry, store|
      enqueue(store, job_id: "new", number: 8, merged_at: T0 + 60)
      enqueue(store, job_id: "old", number: 7, merged_at: T0)
      scheduler = scheduler(entry, store)

      candidates = scheduler.candidates(now: T0 + 120)
      assert_equal %w[old new], candidates.map { |item| item.fetch(:job_id) }
      dispatch = scheduler.reserve(candidates.first, now: T0 + 120)

      assert_equal "refactor-patrol-old", dispatch.fetch(:slug)
      assert_equal "refactor-patrol", dispatch.fetch(:stage)
      assert_includes dispatch.fetch(:command), "--job-manifest"
      assert_includes dispatch.fetch(:command), "--result-file"
      refute_includes dispatch.fetch(:command), " --pr "
      assert_equal "old", dispatch.dig(:dispatch_token, :job_id)
      assert_match(/old-discovery-[a-f0-9]+\.json\z/, dispatch.dig(:dispatch_token, :result_path))
      assert_equal "head", store.read_job("old").fetch("analysis_sha")
    end
  end

  def test_scheduler_uses_the_registered_state_path_for_jobs_and_manifests
    with_tmp_dir do |dir|
      configured = File.join(dir, "state", "hive")
      entry = entry(dir, "demo").merge("hive_state_path" => configured)
      store = Hive::RefactorPatrol::JobStore.new(
        dir, hive_state_path: configured, project: entry
      )
      enqueue(store)
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        repository_resolver: ->(_entry, _cfg) { repository_identity },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a",
        claim_resolver: ->(_attempt) { :resolved }
      )

      candidate = scheduler.candidates(now: T0).fetch(0)

      assert_equal File.join(
        configured, "refactor_patrol", "v2", "manifests", "job-7.json"
      ), candidate.fetch(:manifest_path)
      refute Dir.exist?(File.join(dir, ".hive-state", "refactor_patrol", "v2"))
    end
  end

  def test_reservation_rechecks_migration_ownership_after_candidate_discovery
    with_project do |_dir, entry, store|
      enqueue(store)
      scheduler = scheduler(entry, store)
      candidate = scheduler.candidates(now: T0).first
      scheduler.instance_variable_set(:@migration_ownership, ->(*) { false })

      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        scheduler.reserve(candidate, now: T0)
      end

      assert_equal "migration_ownership_changed", error.reason
    end
  end

  def test_reservation_rejects_a_malformed_live_migration_snapshot
    with_project do |_dir, entry, store|
      enqueue(store)
      scheduler = scheduler(entry, store)
      candidate = scheduler.candidates(now: T0).first
      scheduler.instance_variable_set(
        :@migration_snapshot,
        ->(*) { { "owner" => "legacy", "admission" => true, "epoch" => 0 } }
      )

      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        scheduler.reserve(candidate, now: T0)
      end

      assert_equal "migration_ownership_changed", error.reason
      assert_equal "queued", store.read_job("job-7").fetch("state")
    end
  end

  def test_candidate_pass_snapshots_registration_identity_and_continuation_ledger_once
    with_project do |_dir, entry, store|
      enqueue(store, job_id: "first", number: 7, merged_at: T0)
      enqueue(store, job_id: "second", number: 8, merged_at: T0 + 1)
      identity_calls = 0
      ledger_calls = 0
      ownership = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { [ entry ] },
        config_loader: ->(_path) { enabled_cfg },
        identity_resolver: lambda do |_candidate, _cfg|
          identity_calls += 1
          repository_identity
        end,
        continuation_resolver: lambda do |_candidate, _cfg|
          ledger_calls += 1
          []
        end
      )
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { store },
        repository_ownership: ownership,
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a",
        claim_resolver: ->(_attempt) { :resolved }
      )

      candidates = scheduler.candidates(now: T0 + 2)

      assert_equal %w[first second], candidates.map { |candidate| candidate.fetch(:job_id) }
      assert_equal 1, identity_calls
      assert_equal 1, ledger_calls

      scheduler.reserve(candidates.first, now: T0 + 2)
      assert_equal 2, identity_calls, "reservation must re-resolve live repository identity"
      assert_equal 2, ledger_calls, "reservation must re-read live continuation ownership"
    end
  end

  def test_candidate_pass_accepts_injected_ownership_resolver_without_snapshot_api
    with_project do |_dir, entry, store|
      enqueue(store)
      calls = 0
      ownership = lambda do |**|
        calls += 1
        Hive::RefactorPatrol::RepositoryOwnership::Decision.new(authority: :full)
      end
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { store },
        repository_ownership: ownership,
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a",
        claim_resolver: ->(_attempt) { :resolved }
      )

      assert_equal [ "job-7" ], scheduler.candidates(now: T0).map { |item| item.fetch(:job_id) }
      assert_equal 1, calls
    end
  end

  def test_reserves_classified_job_for_action_resume_without_a_discovery_claim
    with_project do |dir, entry, store|
      write_action_job(dir, store)
      scheduler = scheduler(entry, store)

      candidates = scheduler.candidates(now: T0)
      assert_equal [ :action ], candidates.map { |item| item.fetch(:action_phase) }
      dispatch = scheduler.reserve(candidates.first, now: T0)

      assert_equal "refactor-patrol-action-job-actions", dispatch.fetch(:slug)
      assert_includes dispatch.fetch(:command), "--actions"
      assert_includes dispatch.fetch(:command), "--job-manifest"
      assert_includes dispatch.fetch(:command), "--result-file"
      assert_match(/action-job-action-[a-f0-9]+\.json\z/, dispatch.dig(:dispatch_token, :result_path))
      assert_equal :action, dispatch.dig(:dispatch_token, :phase)
      assert_equal "classified", store.read_job("action-job").fetch("state")
      scheduler.spawned(
        dispatch, pid: 1234, process_start_time: "boot", pgid: 1234, now: T0 + 1
      )
      assert_empty store.read_job("action-job").fetch("actions"),
                   "the child ActionRunner owns the per-action fence"
    end
  end

  def test_malformed_action_child_result_records_durable_action_backoff
    with_project do |dir, entry, store|
      write_action_job(dir, store)
      scheduler = scheduler(entry, store)
      dispatch = scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)

      result = scheduler.complete(
        dispatch_token: dispatch.fetch(:dispatch_token), exit_code: 1,
        envelope: nil, now: T0 + 1
      )

      assert_equal :retry, result.fetch(:status)
      aggregate = store.read_job("action-job")
      assert_equal "action_child_failed_or_signaled", aggregate.fetch("attempts").last.fetch("reason")
      assert_empty scheduler.candidates(now: T0 + 60)
      assert_equal [ "action-job" ], scheduler.candidates(now: T0 + 61).map { |item| item.fetch(:job_id) }
    end
  end

  def test_action_reservation_blocks_when_registered_repository_identity_drifted
    with_project do |dir, entry, store|
      write_action_job(dir, store)
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { repository_identity("other/repository") },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a"
      )
      candidate = scheduler.candidates(now: T0).first

      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        scheduler.reserve(candidate, now: T0)
      end

      assert_equal "repository_identity_drift", error.reason
      aggregate = store.read_job("action-job")
      assert_equal "repository_identity_drift", aggregate.fetch("attempts").last.fetch("reason")
      assert_empty aggregate.fetch("actions")
    end
  end

  def test_repository_drift_does_not_block_reconcile_only_action_continuation
    with_project do |dir, entry, store|
      write_action_job(dir, store)
      initialized = store.initialize_actions!(
        "action-job", specifications: [ { "thesis_id" => "accepted", "kind" => "fix" } ],
        now: T0
      )
      action_id = initialized.fetch("actions").first.fetch("canonical_action_id")
      token = store.claim_action!("action-job", action_id, owner: "seed", now: T0)
      store.record_creation_intent!(
        token,
        intent: {
          "operation" => "create_pr", "canonical_action_id" => action_id,
          "repository" => "acme/demo", "branch" => "hive-refactor/action-job",
          "commit_sha" => "c" * 40
        },
        now: T0
      )
      store.release_action!(token, outcome: "remote_outcome_unknown", now: T0, backoff_sec: 0)
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { repository_identity("other/repository") },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a"
      )

      dispatch = scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)

      assert_equal :action, dispatch.dig(:dispatch_token, :phase)
      assert_includes dispatch.fetch(:command), "--actions"
      refute store.read_job("action-job").fetch("complete")
    end
  end

  def test_duplicate_enabled_repository_registrations_block_with_both_identities_and_backoff
    with_tmp_dir do |root|
      first_dir = File.join(root, "first")
      second_dir = File.join(root, "second")
      [ first_dir, second_dir ].each { |dir| FileUtils.mkdir_p(dir) }
      entries = [ entry(first_dir, "one"), entry(second_dir, "two") ]
      first_store = Hive::RefactorPatrol::JobStore.new(
        first_dir, project: entries.fetch(0)
      )
      enqueue(first_store, registration: "one")
      stores = {
        first_dir => first_store,
        second_dir => Hive::RefactorPatrol::JobStore.new(
          second_dir, project: entries.fetch(1)
        )
      }
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { entries }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(path) { stores.fetch(path) },
        repository_resolver: ->(_entry, _cfg) { repository_identity("Acme/Demo") },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a"
      )

      assert_empty scheduler.candidates(now: T0)
      blocked = first_store.read_job("job-7")
      evidence = blocked.fetch("attempts").last.fetch("evidence")
      assert_equal %w[one two], evidence.fetch("registrations").map { |item| item.fetch("name") }
      assert_empty scheduler.candidates(now: T0 + 30), "durable backoff must avoid per-tick identity work"
    end
  end

  def test_refactor_enabled_duplicate_blocks_even_when_other_daemon_is_disabled
    with_tmp_dir do |root|
      first_dir = File.join(root, "first")
      second_dir = File.join(root, "second")
      [ first_dir, second_dir ].each { |dir| FileUtils.mkdir_p(dir) }
      entries = [ entry(first_dir, "one"), entry(second_dir, "two") ]
      first_store = Hive::RefactorPatrol::JobStore.new(
        first_dir, project: entries.fetch(0)
      )
      enqueue(first_store, registration: "one")
      configs = {
        first_dir => enabled_cfg,
        second_dir => enabled_cfg.merge("daemon" => { "enabled" => false })
      }
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { entries }, config_loader: ->(path) { configs.fetch(path) },
        job_store_factory: ->(_path) { first_store },
        repository_resolver: ->(_entry, _cfg) { repository_identity },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a"
      )

      assert_empty scheduler.candidates(now: T0)
      attempt = first_store.read_job("job-7").fetch("attempts").last
      assert_equal "duplicate_repository_registration", attempt.fetch("reason")
      assert_equal %w[one two], attempt.dig("evidence", "registrations").map { |item| item.fetch("name") }
    end
  end

  def test_origin_becoming_duplicate_between_candidates_and_reserve_blocks_freshly
    with_tmp_dir do |root|
      first_dir = File.join(root, "first")
      second_dir = File.join(root, "second")
      [ first_dir, second_dir ].each { |dir| FileUtils.mkdir_p(dir) }
      entries = [ entry(first_dir, "one"), entry(second_dir, "two") ]
      first_store = Hive::RefactorPatrol::JobStore.new(
        first_dir, project: entries.fetch(0)
      )
      enqueue(first_store, registration: "one")
      stores = {
        first_dir => first_store,
        second_dir => Hive::RefactorPatrol::JobStore.new(
          second_dir, project: entries.fetch(1)
        )
      }
      identities = {
        "one" => repository_identity,
        "two" => repository_identity("acme/other")
      }
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { entries }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(path) { stores.fetch(path) },
        repository_resolver: ->(candidate, _cfg) { identities.fetch(candidate.fetch("name")) },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a"
      )
      candidate = scheduler.candidates(now: T0).first
      identities["two"] = repository_identity

      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        scheduler.reserve(candidate, now: T0)
      end

      assert_equal "duplicate_repository_registration", error.reason
      attempt = first_store.read_job("job-7").fetch("attempts").last
      assert_equal "duplicate_repository_registration", attempt.fetch("reason")
    end
  end

  def test_unregistration_between_candidates_and_reserve_revokes_authority
    with_project do |_dir, entry, store|
      enqueue(store)
      entries = [ entry ]
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { entries }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { repository_identity },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a"
      )
      candidate = scheduler.candidates(now: T0).first
      entries.clear

      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        scheduler.reserve(candidate, now: T0)
      end

      assert_equal "repository_registration_missing", error.reason
      assert_equal "repository_registration_missing",
                   store.read_job("job-7").fetch("attempts").last.fetch("reason")
    end
  end

  def test_duplicate_registration_blocks_action_continuation_with_remote_intent
    with_tmp_dir do |root|
      first_dir = File.join(root, "first")
      second_dir = File.join(root, "second")
      [ first_dir, second_dir ].each { |dir| FileUtils.mkdir_p(dir) }
      entries = [ entry(first_dir, "demo"), entry(second_dir, "duplicate") ]
      first_store = Hive::RefactorPatrol::JobStore.new(
        first_dir, project: entries.fetch(0)
      )
      write_action_job(first_dir, first_store)
      initialized = first_store.initialize_actions!(
        "action-job",
        specifications: [ { "thesis_id" => "accepted", "kind" => "fix" } ],
        now: T0
      )
      action_id = initialized.fetch("actions").first.fetch("canonical_action_id")
      token = first_store.claim_action!("action-job", action_id, owner: "seed", now: T0)
      first_store.record_creation_intent!(
        token,
        intent: {
          "operation" => "create_pr", "canonical_action_id" => action_id,
          "repository" => "acme/demo", "branch" => "hive-refactor/action-job",
          "commit_sha" => "c" * 40
        },
        now: T0
      )
      first_store.release_action!(
        token, outcome: "remote_outcome_unknown", now: T0, backoff_sec: 0
      )
      stores = {
        first_dir => first_store,
        second_dir => Hive::RefactorPatrol::JobStore.new(
          second_dir, project: entries.fetch(1)
        )
      }
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { entries }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(path) { stores.fetch(path) },
        repository_resolver: ->(_entry, _cfg) { repository_identity },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a"
      )

      assert_empty scheduler.candidates(now: T0)
      aggregate = first_store.read_job("action-job")
      assert_equal "duplicate_repository_registration", aggregate.fetch("attempts").last.fetch("reason")
      assert_equal "remote_outcome_unknown", aggregate.fetch("actions").first.fetch("outcome")
    end
  end

  def test_completion_checkpoints_only_exit_zero_schema_valid_exact_complete_envelope
    with_project do |_dir, entry, store|
      enqueue(store)
      scheduler = scheduler(entry, store)
      valid = complete_zero_envelope(entry)
      failures = [
        [ 0, { "schema" => "hive-refactor-patrol" } ],
        [ 0, valid.merge("schema_version" => 2) ],
        [ 1, valid ],
        [ 0, valid.merge("complete" => false, "zero_reason" => nil) ],
        [ 0, valid.merge("job_id" => "wrong-job") ],
        [ 0, valid.merge("source_pr" => valid.fetch("source_pr").merge("repository" => "acme/wrong")) ]
      ]
      now = T0
      failures.each_with_index do |(exit_code, envelope), index|
        dispatch = scheduler.reserve(scheduler.candidates(now: now).first, now: now)
        scheduler.spawned(
          dispatch, pid: 1234 + index, process_start_time: "boot-#{index}",
          pgid: 1234 + index, now: now + 1
        )
        result = scheduler.complete(
          dispatch_token: dispatch.fetch(:dispatch_token), exit_code: exit_code,
          envelope: envelope, now: now + 2
        )
        assert_equal :retry, result.fetch(:status)
        refute store.read_job("job-7").fetch("complete")
        assert_empty store.read_job("job-7").dig("dispositions", "accepted")
        now += 63
      end

      retry_dispatch = scheduler.reserve(scheduler.candidates(now: now).first, now: now)
      scheduler.spawned(retry_dispatch, pid: 2235, process_start_time: "boot-final", pgid: 2235, now: now + 1)
      completed = scheduler.complete(
        dispatch_token: retry_dispatch.fetch(:dispatch_token), exit_code: 0,
        envelope: valid, now: now + 2
      )
      assert_equal :closed, completed.fetch(:status)
      assert store.read_job("job-7").fetch("complete")
      evidence = Hive::Modules::Migration::EvidenceStore.new(
        root: File.join(
          entry.fetch("hive_state_path"), "module-runtime", "migration",
          "patrol-evidence"
        )
      )
      finalized = evidence.captures.find do |capture|
        capture.outcome["completion_status"] == "closed"
      end
      refute_nil finalized
      assert_equal "complete", finalized.outcome.fetch("rationale")
      event = Hive::Modules::EventLedger.new(
        root: File.join(entry.fetch("hive_state_path"), "module-runtime")
      ).all.find do |candidate_event|
        candidate_event.dig(
          "payload", "legacy_mutator_capture", "capture_id"
        ) == finalized.capture_id
      end
      refute_nil event
      assert_equal "legacy_architecture_patrol_completion",
                   event.dig("source", "type")
      assert_empty scheduler.candidates(now: T0 + 3600), "completed zero must be terminal exactly once"
    end
  end

  def test_restart_reconciles_exact_completed_checkpoint_from_active_occurrence
    with_project do |dir, entry, store|
      enqueue(store)
      scheduler = scheduler(entry, store)
      dispatch = scheduler.reserve(
        scheduler.candidates(now: T0).first, now: T0
      )
      scheduler.spawned(
        dispatch,
        pid: 2235,
        process_start_time: "boot-final",
        pgid: 2235,
        now: T0 + 1
      )
      original_settlement = store.method(:settle_effect!)
      failed_intent = nil
      store.define_singleton_method(:settle_effect!) do |intent, **options|
        if failed_intent.nil? &&
           intent.target.end_with?(":checkpoint")
          failed_intent = intent
          raise "simulated receipt crash"
        end

        original_settlement.call(intent, **options)
      end

      assert_raises(RuntimeError) do
        scheduler.complete(
          dispatch_token: dispatch.fetch(:dispatch_token),
          exit_code: 0,
          envelope: complete_zero_envelope(entry),
          now: T0 + 2
        )
      end
      assert store.read_job("job-7").fetch("complete")
      assert_equal "dispatch_uncertain",
                   store.effect_state(failed_intent).fetch("state")

      restarted_store = Hive::RefactorPatrol::JobStore.new(
        dir, project: entry
      )
      restarted = scheduler(entry, restarted_store)
      assert_empty restarted.candidates(now: T0 + 3)

      receipts = Hive::Modules::Migration::EvidenceStore.new(
        root: File.join(
          entry.fetch("hive_state_path"),
          "module-runtime",
          "migration",
          "patrol-evidence"
        )
      ).receipts_for_intent(failed_intent.intent_id).records
      assert_equal [ "reconciled" ],
                   receipts.map(&:status).uniq
      assert_nil restarted_store.occurrence_for_job("job-7"),
                 "fully projected terminal occurrences retire"
    end
  end

  def test_stale_generation_cannot_complete_the_current_claim
    with_project do |_dir, entry, store|
      enqueue(store)
      scheduler = scheduler(entry, store)
      dispatch = scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)
      scheduler.spawned(dispatch, pid: 1234, process_start_time: "boot", pgid: 1234, now: T0 + 1)
      stale = dispatch.fetch(:dispatch_token).merge(generation: dispatch.dig(:dispatch_token, :generation) + 1)

      result = scheduler.complete(
        dispatch_token: stale, exit_code: 0, envelope: complete_zero_envelope(entry), now: T0 + 2
      )

      assert_equal :stale, result.fetch(:status)
      assert_equal "analyzing", store.read_job("job-7").fetch("state")
      assert_equal :closed, scheduler.complete(
        dispatch_token: dispatch.fetch(:dispatch_token), exit_code: 0,
        envelope: complete_zero_envelope(entry), now: T0 + 3
      ).fetch(:status)
    end
  end

  def test_completion_reports_stale_when_the_claim_settles_during_checkpoint
    with_project do |_dir, entry, store|
      enqueue(store)
      scheduler = scheduler(entry, store)
      dispatch = scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)
      scheduler.define_singleton_method(:checkpoint_discovery_through_gateway!) do |*, **|
        raise Hive::RefactorPatrol::JobStore::StaleClaim, "claim already settled"
      end

      result = scheduler.complete(
        dispatch_token: dispatch.fetch(:dispatch_token),
        exit_code: 0,
        envelope: complete_zero_envelope(entry),
        now: T0 + 1
      )

      assert_equal :stale, result.fetch(:status)
      assert_equal "job-7", result.fetch(:job_id)
      assert_equal "analyzing", store.read_job("job-7").fetch("state")
    end
  end

  def test_reserve_reclaims_expired_discovery_claim_only_when_owner_is_provably_resolved
    with_project do |_dir, entry, store|
      enqueue(store)
      dead = store.claim_discovery!(
        "job-7", owner: "daemon-crashed", analysis_sha: "head",
        now: T0, lease_sec: 60, owner_pid: 4242, owner_process_start_time: "boot-dead"
      )
      store.attach_discovery_process!(
        dead, pid: 4242, process_start_time: "boot-dead", pgid: 4242,
        now: T0 + 1, lease_sec: 60
      )

      cautious = scheduler(entry, store, claim_resolver: ->(_claim) { :unresolved })
      candidates = cautious.candidates(now: T0 + 120)
      assert_equal [ "job-7" ], candidates.map { |item| item.fetch(:job_id) },
                   "an analyzing job with an expired claim must surface for recovery"
      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        cautious.reserve(candidates.first, now: T0 + 120)
      end
      assert_equal "claim_unavailable", error.reason
      unresolved = store.read_job("job-7").fetch("attempts").last
      assert_equal "running", unresolved.fetch("state"),
                   "an unresolved owner must keep its recorded claim"
      assert_equal "daemon-crashed", unresolved.fetch("owner")

      resolved_claims = []
      recovering = scheduler(entry, store, claim_resolver: lambda { |claim|
        resolved_claims << claim
        :resolved
      })
      dispatch = recovering.reserve(recovering.candidates(now: T0 + 120).first, now: T0 + 120)

      assert_equal "job-7", dispatch.dig(:dispatch_token, :job_id)
      assert_equal dead.fetch(:generation) + 1, dispatch.dig(:dispatch_token, :generation)
      assert_equal [ 4242 ], resolved_claims.map { |claim| claim.fetch("pid") },
                   "the injected resolver must receive the recorded claim evidence"
      attempts = store.read_job("job-7").fetch("attempts")
      assert_equal "superseded", attempts[-2].fetch("state")
      assert_equal "expired_claim_resolved", attempts[-2].fetch("outcome")
      assert_equal "claimed", attempts[-1].fetch("state")
      assert_equal "daemon-a", attempts[-1].fetch("owner")
    end
  end

  def test_spawn_transition_renews_discovery_lease_from_verified_child_start
    with_project do |_dir, entry, store|
      enqueue(store)
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { repository_identity },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a",
        claim_resolver: ->(_attempt) { :resolved }, lease_sec: 60
      )
      dispatch = scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)

      scheduler.spawned(
        dispatch, pid: 1234, process_start_time: "boot", pgid: 1234,
        now: T0 + 50
      )

      claim = store.read_job("job-7").fetch("attempts").last
      assert_equal "running", claim.fetch("state")
      assert_equal (T0 + 110).iso8601, claim.fetch("expires_at")
    end
  end

  def test_pinned_partial_job_reuses_exact_analysis_sha_when_default_branch_advances
    with_project do |_dir, entry, store|
      enqueue(store)
      first = scheduler(entry, store)
      dispatch = first.reserve(first.candidates(now: T0).first, now: T0)
      first.cancel(dispatch, reason: "partial_review", now: T0)
      advanced = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { repository_identity },
        checkout_guard_factory: ->(*) { Guard.new(sha: "advanced-head") },
        owner: "daemon-b"
      )

      resumed = advanced.reserve(advanced.candidates(now: T0 + 60).first, now: T0 + 60)

      assert_equal "head", resumed.dig(:dispatch_token, :analysis_sha)
      aggregate = store.read_job("job-7")
      assert_equal "head", aggregate.fetch("analysis_sha")
      assert_equal "claimed", aggregate.fetch("attempts").last.fetch("state")
    end
  end

  def test_partial_envelope_checkpoints_completed_feature_before_retry
    with_project do |_dir, entry, store|
      enqueue(store)
      scheduler = scheduler(entry, store)
      dispatch = scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)
      scheduler.spawned(dispatch, pid: 1234, process_start_time: "boot", pgid: 1234, now: T0 + 1)
      error = { "feature_id" => "search", "error" => "agent_failed", "message" => "timeout" }
      partial = complete_zero_envelope(entry).merge(
        "complete" => false,
        "features_mapped" => 2,
        "review_errors" => [ error ],
        "feature_results" => [
          { "feature_id" => "checkout", "complete" => true, "thesis_ids" => [], "errors" => [] },
          { "feature_id" => "search", "complete" => false, "thesis_ids" => [], "errors" => [ error ] }
        ],
        "zero_reason" => nil
      )

      result = scheduler.complete(
        dispatch_token: dispatch.fetch(:dispatch_token), exit_code: 0,
        envelope: partial, now: T0 + 2
      )

      assert_equal :retry, result.fetch(:status)
      aggregate = store.read_job("job-7")
      assert_equal [ "checkout" ], aggregate.fetch("feature_results").map { |item| item.fetch("feature_id") }
      assert_equal [ error ], aggregate.fetch("review_errors")
      assert_empty scheduler.candidates(now: T0 + 61)
      assert_equal [ "job-7" ], scheduler.candidates(now: T0 + 62).map { |item| item.fetch(:job_id) }
    end
  end

  def test_clean_bounded_progress_retries_without_a_review_error
    with_project do |_dir, entry, store|
      enqueue(store)
      scheduler = scheduler(entry, store)
      dispatch = scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)
      scheduler.spawned(dispatch, pid: 1234, process_start_time: "boot", pgid: 1234, now: T0 + 1)
      partial = complete_zero_envelope(entry).merge(
        "complete" => false,
        "review_errors" => [],
        "feature_results" => [
          { "feature_id" => "checkout", "complete" => true, "thesis_ids" => [], "errors" => [] }
        ],
        "zero_reason" => nil
      )

      result = scheduler.complete(
        dispatch_token: dispatch.fetch(:dispatch_token), exit_code: 0,
        envelope: partial, now: T0 + 2
      )

      assert_equal :retry, result.fetch(:status)
      aggregate = store.read_job("job-7")
      assert_equal [ "checkout" ], aggregate.fetch("feature_results").map { |item| item.fetch("feature_id") }
      assert_empty aggregate.fetch("review_errors")
      assert_empty scheduler.candidates(now: T0 + 61)
      assert_equal [ "job-7" ], scheduler.candidates(now: T0 + 62).map { |item| item.fetch(:job_id) }
    end
  end

  def test_daily_patrol_quota_exhaustion_backs_off_until_next_utc_day
    %w[
      daily_agent_spawn_limit daily_architecture_unmetered_spawn_limit
      daily_architecture_review_spawn_limit daily_token_headroom daily_token_limit
    ].each do |reason|
      with_project do |_dir, entry, store|
        enqueue(store)
        scheduler = scheduler(entry, store)
        dispatch = scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)
        scheduler.spawned(dispatch, pid: 1234, process_start_time: "boot", pgid: 1234, now: T0 + 1)
        error = {
          "feature_id" => "checkout", "error" => "agent_failed", "message" => "daily quota exhausted",
          "details" => {
            "resource_exhaustion" => {
              "reason" => reason, "limit" => 8, "observed" => 8
            }
          }
        }
        partial = complete_zero_envelope(entry).merge(
          "complete" => false,
          "review_errors" => [ error ],
          "feature_results" => [
            { "feature_id" => "checkout", "complete" => false, "thesis_ids" => [], "errors" => [ error ] }
          ],
          "zero_reason" => nil
        )

        result = scheduler.complete(
          dispatch_token: dispatch.fetch(:dispatch_token), exit_code: 0,
          envelope: partial, now: T0 + 2
        )

        assert_equal :retry, result.fetch(:status), reason
        assert_empty scheduler.candidates(now: Time.utc(2026, 7, 10, 23, 59, 59)), reason
        assert_equal [ "job-7" ], scheduler.candidates(now: Time.utc(2026, 7, 11)).map { |item| item.fetch(:job_id) }, reason
      end
    end
  end

  def test_dry_run_leaves_authoritative_job_bytes_unchanged
    with_project do |dir, entry, store|
      enqueue(store)
      path = File.join(store.root, "jobs", "job-7.json")
      before = File.binread(path)
      dry_scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { repository_identity },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a", dry_run: true
      )

      dispatch = dry_scheduler.reserve(dry_scheduler.candidates(now: T0).first, now: T0)
      dry_scheduler.spawned(dispatch, pid: -1, process_start_time: nil, pgid: nil, now: T0 + 1)
      result = dry_scheduler.complete(
        dispatch_token: dispatch.fetch(:dispatch_token), exit_code: 0, envelope: nil, now: T0 + 2
      )

      assert_equal :dry_run, result.fetch(:status)
      assert_equal before, File.binread(path)
      refute File.exist?(File.join(dir, "patrol_arbiter.json"))
    end
  end

  def test_process_group_resolver_fails_closed_on_unverified_or_wrong_pgid_identity
    resolver = Hive::Daemon::RefactorPatrolScheduler::ProcessGroupResolver.new
    assert_equal :resolved, resolver.call(
      "pid" => 999_999, "pgid" => 999_999, "process_start_time" => ""
    )
    assert_equal :resolved, resolver.call(
      "pid" => 999_999, "pgid" => 999_999, "process_start_time" => "recorded"
    )
    assert_equal :resolved, resolver.call(
      "pid" => nil, "owner_pid" => 999_999, "owner_process_start_time" => "recorded"
    )

    live_start = Hive::Lock.process_start_time(Process.pid)
    skip "process start identity unavailable" if live_start.to_s.empty?
    assert_equal :unresolved, resolver.call(
      "pid" => nil, "owner_pid" => Process.pid, "owner_process_start_time" => ""
    )
    assert_equal :unresolved, resolver.call(
      "pid" => nil, "owner_pid" => Process.pid, "owner_process_start_time" => live_start
    )
    assert_equal :unresolved, resolver.call(
      "pid" => Process.pid, "pgid" => Process.getpgid(Process.pid) + 1,
      "process_start_time" => live_start
    )
  end

  def test_scheduler_blocks_before_claim_when_owner_process_identity_is_unavailable
    with_project do |_dir, entry, store|
      enqueue(store)
      instance = scheduler(entry, store)
      instance.instance_variable_set(:@owner_process_start_time, nil)

      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        instance.reserve(instance.candidates(now: T0).first, now: T0)
      end

      assert_equal "process_identity_unavailable", error.reason
      aggregate = store.read_job("job-7")
      assert_equal "process_identity_unavailable", aggregate.fetch("attempts").last.fetch("reason")
      refute_equal "analyzing", aggregate.fetch("state")
    end
  end

  def test_broken_project_config_is_a_visible_durable_block
    [
      ->(_path) { raise Hive::ConfigError, "invalid config" },
      ->(_path) { YAML.safe_load("refactor_patrol: [") }
    ].each do |loader|
      with_project do |_dir, entry, store|
        enqueue(store)
        scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
          registry: -> { [ entry ] }, config_loader: loader,
          job_store_factory: ->(_path) { store },
          repository_resolver: ->(_entry, _cfg) { repository_identity },
          checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a"
        )

        assert_empty scheduler.candidates(now: T0)
        event = scheduler.drain_events.last
        assert_equal "project_config_unavailable", event.fetch(:reason)
        aggregate = store.read_job("job-7")
        assert_equal "project_config_unavailable", aggregate.fetch("attempts").last.fetch("reason")
      end
    end
  end

  def test_config_breaking_between_candidate_and_reserve_blocks_durably
    with_project do |_dir, entry, store|
      enqueue(store)
      broken = false
      loader = lambda do |_path|
        raise Hive::ConfigError, "became malformed" if broken

        enabled_cfg
      end
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: loader,
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { repository_identity },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a"
      )
      candidate = scheduler.candidates(now: T0).first
      broken = true

      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        scheduler.reserve(candidate, now: T0)
      end

      assert_equal "project_config_unavailable", error.reason
      assert_equal "project_config_unavailable",
                   store.read_job("job-7").fetch("attempts").last.fetch("reason")
    end
  end

  def test_default_factories_resolve_config_store_checkout_and_repository_identity
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(
        File.join(dir, ".hive-state", "config.yml"),
        Hive::Config.deep_merge(
          Hive::Config.deep_dup(Hive::Config::DEFAULTS),
          "project_name" => "demo", "default_branch" => "main"
        ).to_yaml
      )
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(registry: -> { [] })

      assert_equal "demo", scheduler.instance_variable_get(:@config_loader).call(dir).fetch("project_name")
      assert_instance_of Hive::RefactorPatrol::JobStore,
                         scheduler.send(
                           :store_for,
                           entry(dir, "demo")
                         )
      assert_instance_of Hive::RefactorPatrol::CheckoutGuard,
                         scheduler.instance_variable_get(:@checkout_guard_factory).call(dir, "main")
      expected = repository_identity
      with_replaced_singleton_method(Hive::Gh, :repository_identity, ->(*, **) { expected }) do
        entry = { "name" => "demo", "path" => dir }
        assert_equal expected,
                     scheduler.instance_variable_get(:@repository_resolver).call(entry, {})
      end
    end
  end

  def test_disabled_discovery_is_not_a_candidate_and_reservation_fails_closed
    with_project do |_dir, entry, store|
      enqueue(store)
      cfg = enabled_cfg
      cfg.fetch("refactor_patrol")["enabled"] = false
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { cfg },
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { repository_identity },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a"
      )

      assert_empty scheduler.candidates(now: T0)
      aggregate = store.read_job("job-7")
      candidate = scheduler.send(:candidate_for, entry, aggregate, phase: :discovery)
      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        scheduler.reserve(candidate, now: T0)
      end
      assert_equal "architecture_patrol_disabled", error.reason
    end
  end

  def test_candidate_store_failure_is_reported_as_scheduler_error
    with_tmp_dir do |dir|
      entry = entry(dir, "demo")
      failing_store = Object.new
      failing_store.define_singleton_method(
        :each_recovery_active_occurrence
      ) { |&| nil }
      install_recovery_protocol(failing_store)
      failing_store.define_singleton_method(:claimable_jobs) do |**|
        raise Hive::RefactorPatrol::JobStore::CorruptRecord, "broken index"
      end
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { failing_store },
        repository_resolver: ->(_entry, _cfg) { repository_identity }
      )

      assert_empty scheduler.candidates(now: T0)
      event = scheduler.drain_events.fetch(0)
      assert_equal "scheduler_error", event.fetch(:reason)
      assert_match(/broken index/, event.fetch(:error))
    end
  end

  def test_occurrence_recovery_failure_is_identified_and_backed_off
    with_tmp_dir do |dir|
      entry = entry(dir, "demo")
      capture = Hive::Modules::Migration::PatrolCapture.build(
        module_name: "architecture-patrol",
        project: {
          "project_id" => entry.fetch("project_id"),
          "name" => entry.fetch("name"),
          "repository" => "acme/demo"
        },
        trigger: { "kind" => "pull_request.merged", "id" => "merge-7" },
        reservation: {
          "kind" => "architecture",
          "id" => "job-7",
          "job_id" => "job-7"
        },
        owner: "legacy",
        owner_epoch: 1,
        selection_input: {
          "kind" => "candidate",
          "job_id" => "job-7",
          "phase" => "discovery"
        },
        selection:
          Hive::Modules::Migration::PatrolDecisionProjection.build(
            module_name: "architecture-patrol",
            rationale: "due",
            job_id: "job-7",
            phase: "discovery"
          ),
        outcome_class: nil,
        outcome: nil,
        occurred_at: T0,
        recorded_at: T0
      )
      reads = 0
      failing_store = Object.new
      failing_store.define_singleton_method(
        :each_recovery_active_occurrence
      ) do |&block|
        block.call(
          "occurrence_id" => capture.occurrence_id,
          "phase" => "reserved",
          "provisional_capture" => capture.to_h,
          "outbox" => []
        )
      end
      failing_store.define_singleton_method(:read_job) do |_job_id|
        reads += 1
        raise Hive::RefactorPatrol::JobStore::CorruptRecord,
              "recovery failed: #{"x" * 600}"
      end
      install_recovery_protocol(failing_store)
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] },
        config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { failing_store },
        repository_resolver: ->(_entry, _cfg) { repository_identity }
      )

      assert_empty scheduler.candidates(now: T0)
      first = scheduler.drain_events.fetch(0)
      assert_equal "demo", first.fetch(:project)
      assert_equal capture.occurrence_id,
                   first.fetch(:occurrence_id)
      assert_equal "job-7", first.fetch(:job_id)
      assert_equal "architecture_occurrence",
                   first.fetch(:recovery)
      assert_equal "CorruptRecord", first.fetch(:error_class).split("::").last
      assert_equal 512, first.fetch(:error).bytesize
      assert_equal 1, first.fetch(:retry_count)
      assert_equal 60, first.fetch(:retry_in_sec)
      durable = failing_store.recovery_backoff(now: T0).fetch(
        "failure"
      )
      assert_equal durable.fetch("error_class"),
                   first.fetch(:error_class)
      assert_equal durable.fetch("error_message"),
                   first.fetch(:error)

      assert_empty scheduler.candidates(now: T0 + 59)
      assert_empty scheduler.drain_events
      assert_equal 1, reads

      assert_empty scheduler.candidates(now: T0 + 60)
      second = scheduler.drain_events.fetch(0)
      assert_equal 2, reads
      assert_equal 2, second.fetch(:retry_count)
      assert_equal 300, second.fetch(:retry_in_sec)
    end
  end

  def test_merged_pr_retirement_compacts_and_fences_replay_after_restart
    with_tmp_dir do |dir|
      journal_root = File.join(dir, "architecture-occurrences")
      captures = []

      with_constant(
        Hive::Modules::Migration::OccurrenceJournalState,
        :MAX_SEQUENCE_HIGH_WATERS,
        2
      ) do
        3.times do |index|
          timestamp = T0 + index
          value = manifest(
            job_id: "job-#{index + 1}",
            number: index + 1,
            merged_at: timestamp,
            registration: "demo"
          )
          capture =
            Hive::RefactorPatrol::TransitionGateway
            .capture_for_manifest(
              manifest: value,
              project_id: "demo-id",
              owner: "legacy",
              owner_epoch: 1,
              recorded_at: timestamp
            )
          captures << capture
          assert_equal "architecture",
                       capture.reservation.fetch("kind")
          assert_equal timestamp.iso8601(6),
                       capture.reservation.fetch(
                         "window_started_at"
                       )
          assert_equal 1,
                       capture.reservation.fetch(
                         "attempt_generation"
                       )
          journal =
            Hive::Modules::Migration::OccurrenceJournal.new(
              journal_root,
              module_name: "architecture-patrol"
            )
          journal.reserve!(capture, now: timestamp)
          final = Hive::Modules::Migration::PatrolCapture.build(
            module_name: capture.module_name,
            project: capture.project,
            trigger: capture.trigger,
            reservation: capture.reservation,
            owner: capture.owner,
            owner_epoch: capture.owner_epoch,
            selection_input: capture.selection_input,
            selection: capture.selection,
            outcome_class: "complete",
            outcome: { "rationale" => "complete" },
            occurred_at: capture.occurred_at,
            recorded_at: timestamp + 1
          )
          journal.finalize!(final, now: timestamp + 1)
          journal.pending_outbox(
            capture.occurrence_id
          ).each do |entry|
            journal.acknowledge_outbox!(
              capture.occurrence_id,
              entry_id: entry.fetch("id"),
              digest: entry.fetch("digest")
            )
          end
          assert_nil Hive::Modules::Migration::OccurrenceJournal.new(
            journal_root,
            module_name: "architecture-patrol"
          ).fetch(capture.occurrence_id)
        end

        restarted =
          Hive::Modules::Migration::OccurrenceJournal.new(
            journal_root,
            module_name: "architecture-patrol"
          )
        assert_raises(Hive::ConfigError) do
          restarted.reserve!(captures.first, now: T0 + 3)
        end
        later_manifest = manifest(
          job_id: "job-4",
          number: 4,
          merged_at: T0 + 4,
          registration: "demo"
        )
        later =
          Hive::RefactorPatrol::TransitionGateway
          .capture_for_manifest(
            manifest: later_manifest,
            project_id: "demo-id",
            owner: "legacy",
            owner_epoch: 1,
            recorded_at: T0 + 4
          )
        restarted.reserve!(later, now: T0 + 4)
        assert_equal later.occurrence_id,
                     restarted.fetch(
                       later.occurrence_id
                     ).fetch("occurrence_id")
      end
    end
  end

  def test_architecture_producers_build_the_same_canonical_occurrence
    value = manifest(
      job_id: "job-7",
      number: 7,
      merged_at: T0,
      registration: "demo"
    )
    transition_capture =
      Hive::RefactorPatrol::TransitionGateway.capture_for_manifest(
        manifest: value,
        project_id: "demo-id",
        owner: "legacy",
        owner_epoch: 1,
        recorded_at: T0
      )
    reserved = nil
    store = Object.new
    store.define_singleton_method(
      :occurrence_capture
    ) { |_job_id| nil }
    store.define_singleton_method(
      :reserve_occurrence!
    ) do |_job_id, capture:, now:|
      reserved = [ capture, now ]
    end
    lifecycle =
      Hive::RefactorPatrol::ArchitectureOccurrenceLifecycle.new(
        migration_authority: :legacy,
        dry_run: false,
        evidence_store_factory: ->(_entry) { Object.new },
        event_publisher: Object.new,
        module_schedule: "*/10 * * * *",
        reservation_error:
          Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked
      )
    lifecycle_capture = lifecycle.reserve(
      store: store,
      entry: {
        "project_id" => "demo-id",
        "name" => "demo"
      },
      aggregate: {
        "job_id" => value.fetch("job_id"),
        "created_at" => T0.iso8601,
        "source" =>
          value.fetch("source").merge(
            "manifest_checksum" =>
              value.fetch("manifest_checksum")
          )
      },
      migration: {
        "owner" => "legacy",
        "epoch" => 1
      },
      now: T0
    )

    assert_equal transition_capture.to_h,
                 lifecycle_capture.to_h
    assert_equal [ lifecycle_capture, T0 ], reserved
  end

  def test_recovery_store_initialization_errors_keep_the_original_diagnostic
    with_tmp_dir do |dir|
      project = entry(dir, "demo")
      error_class = Class.new(StandardError)
      original = error_class.new("state unavailable: \xFF".b)
      expected =
        Hive::Modules::Migration::OccurrenceJournalState
        .normalize_error(original)
      masking_store = Object.new
      masking_store.define_singleton_method(:recovery_backoff) do |now:|
        now
        raise original
      end
      masking_store.define_singleton_method(
        :record_recovery_failure!
      ) do |**|
        raise RuntimeError, "masking persistence error"
      end
      factories = [
        ->(_path) { raise original },
        ->(_path) { masking_store }
      ]

      factories.each do |factory|
        scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
          registry: -> { [ project ] },
          config_loader: ->(_path) { enabled_cfg },
          job_store_factory: factory,
          repository_resolver: ->(_entry, _cfg) {
            repository_identity
          }
        )

        assert_empty scheduler.candidates(now: T0)
        event = scheduler.drain_events.fetch(0)
        assert_equal "recovery_state_unavailable",
                     event.fetch(:blocker)
        assert_equal expected.fetch("error_class"),
                     event.fetch(:error_class)
        assert_equal expected.fetch("error_message"),
                     event.fetch(:error)
        assert event.fetch(:error).valid_encoding?
        refute_match(/masking persistence/, event.fetch(:error))
      end
    end
  end

  def test_recovery_persistence_failure_and_unscoped_failure_are_reported
    with_tmp_dir do |dir|
      project = entry(dir, "demo")
      capture = Hive::Modules::Migration::PatrolCapture.build(
        module_name: "architecture-patrol",
        project: {
          "project_id" => project.fetch("project_id"),
          "name" => project.fetch("name"),
          "repository" => "acme/demo"
        },
        trigger: { "kind" => "pull_request.merged", "id" => "merge-7" },
        reservation: {
          "kind" => "architecture",
          "id" => "job-7",
          "job_id" => "job-7"
        },
        owner: "legacy",
        owner_epoch: 1,
        selection_input: {
          "kind" => "candidate",
          "job_id" => "job-7",
          "phase" => "discovery"
        },
        selection:
          Hive::Modules::Migration::PatrolDecisionProjection.build(
            module_name: "architecture-patrol",
            rationale: "due",
            job_id: "job-7",
            phase: "discovery"
          ),
        outcome_class: nil,
        outcome: nil,
        occurred_at: T0,
        recorded_at: T0
      )
      occurrence_failure = Object.new
      occurrence_failure.define_singleton_method(
        :each_recovery_active_occurrence
      ) do |&block|
        block.call(
          "occurrence_id" => capture.occurrence_id,
          "phase" => "reserved",
          "provisional_capture" => capture.to_h,
          "outbox" => []
        )
      end
      occurrence_failure.define_singleton_method(:recovery_backoff) do |now:|
        now
        { "generation" => 0, "failure" => nil, "blocked" => false }
      end
      occurrence_failure.define_singleton_method(:read_job) do |_job_id|
        raise Hive::RefactorPatrol::JobStore::CorruptRecord,
              "occurrence recovery failed"
      end
      occurrence_failure.define_singleton_method(
        :record_recovery_failure!
      ) { |**| raise IOError, "journal unavailable" }
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ project ] },
        config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { occurrence_failure },
        repository_resolver: ->(_entry, _cfg) { repository_identity }
      )

      assert_empty scheduler.candidates(now: T0)
      unavailable = scheduler.drain_events.fetch(0)
      assert_equal "recovery_state_unavailable",
                   unavailable.fetch(:blocker)
      assert_equal capture.occurrence_id,
                   unavailable.fetch(:occurrence_id)

      unscoped_failure = Object.new
      install_recovery_protocol(unscoped_failure)
      unscoped_failure.define_singleton_method(
        :each_recovery_active_occurrence
      ) { raise IOError, "inventory unavailable" }
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ project ] },
        config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { unscoped_failure },
        repository_resolver: ->(_entry, _cfg) { repository_identity }
      )

      assert_empty scheduler.candidates(now: T0)
      blocked = scheduler.drain_events.fetch(0)
      assert_equal "recovery_failed", blocked.fetch(:blocker)
      assert_nil blocked.fetch(:occurrence_id)
      assert_nil blocked.fetch(:job_id)
      assert_equal 1, blocked.fetch(:retry_count)
    end
  end

  def test_checkout_guard_error_is_durably_blocked_with_specific_reason
    with_project do |_dir, entry, store|
      enqueue(store)
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { repository_identity },
        checkout_guard_factory: ->(*) {
          Object.new.tap do |guard|
            guard.define_singleton_method(:validate_and_snapshot!) do |**|
              raise Hive::GitError, "dirty checkout"
            end
          end
        }, owner: "daemon-a"
      )

      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)
      end

      assert_equal "checkout_guard", error.reason
      assert_equal "checkout_guard", store.read_job("job-7").fetch("attempts").last.fetch("reason")
    end
  end

  def test_cancel_ignores_a_claim_that_settled_after_dispatch_snapshot
    with_project do |_dir, entry, store|
      scheduler = scheduler(entry, store)
      store.define_singleton_method(:occurrence_capture) { |_job_id| nil }
      store.define_singleton_method(:release_discovery!) do |*|
        raise Hive::RefactorPatrol::JobStore::StaleClaim, "already settled"
      end
      dispatch = {
        entry: entry,
        dispatch_token: { phase: :discovery, job_id: "job-7", generation: 1 }
      }

      assert_nil scheduler.cancel(dispatch, reason: "spawn_failed", now: T0)
    end
  end

  def test_completion_release_failure_is_contained_and_retried
    with_tmp_dir do |dir|
      entry = entry(dir, "demo")
      aggregate = {
        "job_id" => "job-7", "source" => { "registration" => "demo" },
        "dispositions" => { "accepted" => [], "flagged" => [], "suppressed" => [] },
        "actions" => []
      }
      failing_store = Object.new
      failing_store.define_singleton_method(:read_job) { |_job_id| aggregate }
      failing_store.define_singleton_method(:release_discovery!) do |*|
        raise Hive::RefactorPatrol::JobStore::CorruptRecord, "cannot update claim"
      end
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { failing_store },
        repository_resolver: ->(_entry, _cfg) { repository_identity }
      )
      token = { registration: "demo", job_id: "job-7", phase: :discovery }

      result = scheduler.complete(
        dispatch_token: token, exit_code: 1, envelope: nil, now: T0
      )

      assert_equal :retry, result.fetch(:status)
    end
  end

  def test_configuration_block_failure_is_exposed_without_crashing_candidate_scan
    with_tmp_dir do |dir|
      entry = entry(dir, "demo")
      store = Object.new
      store.define_singleton_method(:claimable_jobs) do |**|
        raise Hive::RefactorPatrol::JobStore::CorruptRecord, "cannot inventory jobs"
      end
      store.define_singleton_method(:actionable_jobs) { |**| [] }
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] },
        config_loader: ->(_path) { raise Hive::ConfigError, "broken config" },
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { repository_identity }
      )

      assert_empty scheduler.candidates(now: T0)
      event = scheduler.drain_events.fetch(0)
      assert_equal "project_config_unavailable", event.fetch(:reason)
      assert_match(/cannot inventory jobs/, event.fetch(:error))
    end
  end

  def test_action_continuation_converts_disabled_discovery_to_continuation_authority
    decision = Hive::RefactorPatrol::RepositoryOwnership::Decision.new(
      authority: :blocked, reason: "architecture_patrol_disabled", evidence: { "enabled" => false }
    )
    scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
      registry: -> { [] }, repository_ownership: ->(**) { decision }
    )
    entry = { "name" => "demo", "path" => "/tmp/demo", "_refactor_patrol_cfg" => enabled_cfg }
    aggregate = { "job_id" => "job-7", "source" => {}, "actions" => [] }

    converted = scheduler.send(
      :repository_ownership_decision, entry, aggregate, phase: :action
    )

    assert_equal :continuation_only, converted.authority
    assert_equal "architecture_patrol_disabled", converted.reason
  end

  def test_block_store_failure_still_emits_a_visible_event
    with_tmp_dir do |dir|
      entry = entry(dir, "demo")
      store = Object.new
      store.define_singleton_method(:block_discovery!) do |*|
        raise Hive::RefactorPatrol::JobStore::CorruptRecord, "write failed"
      end
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, job_store_factory: ->(_path) { store },
        repository_ownership: ->(**) { flunk "ownership is not consulted" }
      )

      scheduler.send(
        :block, entry, { "job_id" => "job-7", "source" => {} },
        reason: "test_block", evidence: {}, now: T0
      )

      event = scheduler.drain_events.fetch(0)
      assert_equal "test_block", event.fetch(:reason)
      assert_match(/write failed/, event.fetch(:error))
    end
  end

  def test_manifest_and_claim_registration_mismatches_are_rejected
    with_project do |dir, entry, store|
      enqueue(store)
      aggregate = store.read_job("job-7")
      manifest_path = File.join(
        dir, ".hive-state", "refactor_patrol", "v2", "manifests", "job-7.json"
      )
      manifest = JSON.parse(File.read(manifest_path))
      conflicting = aggregate.merge("source" => aggregate.fetch("source").merge("url" => "https://github.com/acme/demo/pull/changed"))
      scheduler = scheduler(entry, store)

      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        scheduler.send(:assert_manifest_matches!, manifest_path, conflicting)
      end
      store.define_singleton_method(:read_job) do |_job_id|
        aggregate.merge("source" => aggregate.fetch("source").merge("registration" => "other"))
      end
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        scheduler.send(:entry_for_token, registration: "demo", job_id: "job-7")
      end
      assert_equal "job-7", manifest.fetch("job_id")
    end
  end

  def test_action_missing_envelope_and_completion_projection_include_pending_actions
    scheduler = Hive::Daemon::RefactorPatrolScheduler.new(registry: -> { [] })
    assert_equal "action_missing_envelope",
                 scheduler.send(:action_completion_failure_reason, 0, nil)
    assert_equal "action_malformed_or_mismatched_envelope",
                 scheduler.send(:action_completion_failure_reason, 0, {})
    aggregate = {
      "source" => { "number" => 7, "url" => "url" },
      "dispositions" => { "accepted" => [ {} ], "flagged" => [], "suppressed" => [] },
      "actions" => [
        { "canonical_action_id" => "done", "outcome" => "pr_opened", "terminal" => true },
        { "canonical_action_id" => "pending", "outcome" => "claimed", "terminal" => false }
      ]
    }

    projection = scheduler.send(
      :completion_result, :retry, { job_id: "job-7" }, nil, aggregate: aggregate
    )

    assert_equal :retry, projection.fetch(:status)
    assert_equal "job-7", projection.fetch(:job_id)
    assert_equal 7, projection.fetch(:pr_number)
    assert_equal "url", projection.fetch(:pr_url)
    assert_equal 1, projection.fetch(:accepted_count)
    assert_equal 0, projection.fetch(:flagged_count)
    assert_equal 0, projection.fetch(:suppressed_count)
    assert_equal 2, projection.fetch(:action_count)
    assert_equal 1, projection.fetch(:terminal_action_count)
    assert_equal [ "pending" ], projection.fetch(:pending_action_ids)
    assert_equal({ "done" => "pr_opened", "pending" => "claimed" }, projection.fetch(:action_outcomes))

    classified = scheduler.send(
      :completion_result,
      :classified,
      { job_id: "job-7" },
      {
        "accepted" => [ {}, {} ],
        "flagged" => [ {} ],
        "suppressed" => []
      },
      aggregate: aggregate
    )
    assert_equal :classified, classified.fetch(:status)
    assert_equal 2, classified.fetch(:accepted_count)
    assert_equal 1, classified.fetch(:flagged_count)
    assert_equal({ "done" => "pr_opened", "pending" => "claimed" }, classified.fetch(:action_outcomes))
    assert_equal Time.at(0).utc, scheduler.send(:parse_time, "not-a-time")
  end

  def test_broken_project_config_blocks_pending_action_work_too
    with_project do |dir, entry, store|
      write_action_job(dir, store)
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] },
        config_loader: ->(_path) { raise Hive::ConfigError, "invalid config" },
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { repository_identity },
        checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a"
      )

      assert_empty scheduler.candidates(now: T0)

      aggregate = store.read_job("action-job")
      assert_equal "project_config_unavailable", aggregate.fetch("attempts").last.fetch("reason")
    end
  end

  def test_valid_incomplete_action_envelope_reports_action_pending
    with_project do |dir, entry, store|
      write_action_job(dir, store)
      aggregate = store.read_job("action-job")
      scheduler = scheduler(entry, store)
      token = { registration: "demo", job_id: "action-job", phase: :action }
      envelope = action_envelope(entry, aggregate)

      result = scheduler.complete(
        dispatch_token: token, exit_code: 0, envelope: envelope, now: T0
      )

      assert_equal :action_pending, result.fetch(:status)
    end
  end

  def test_valid_complete_action_envelope_reports_closed_and_store_errors_retry
    with_project do |dir, entry, store|
      write_action_job(dir, store)
      aggregate = store.read_job("action-job").merge("complete" => true, "state" => "complete")
      fake_store = Object.new
      fake_store.define_singleton_method(:read_job) { |_job_id| aggregate }
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { fake_store },
        repository_resolver: ->(_entry, _cfg) { repository_identity }
      )
      token = { registration: "demo", job_id: "action-job", phase: :action }
      envelope = action_envelope(entry, aggregate)

      assert_equal :closed, scheduler.complete(
        dispatch_token: token, exit_code: 0, envelope: envelope, now: T0
      ).fetch(:status)

      fake_store.define_singleton_method(:block_actions!) do |*|
        raise Hive::RefactorPatrol::JobStore::CorruptRecord, "cannot persist block"
      end
      assert_equal :retry, scheduler.complete(
        dispatch_token: token, exit_code: 0, envelope: {}, now: T0
      ).fetch(:status)
    end
  end

  private

  def with_project
    with_tmp_dir do |dir|
      entry = entry(dir, "demo")
      yield(
        dir,
        entry,
        Hive::RefactorPatrol::JobStore.new(dir, project: entry)
      )
    end
  end

  def scheduler(entry, store, claim_resolver: ->(_attempt) { :resolved })
    Hive::Daemon::RefactorPatrolScheduler.new(
      registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
      job_store_factory: ->(_path) { store },
      repository_resolver: ->(_entry, _cfg) { repository_identity },
      checkout_guard_factory: ->(*) { Guard.new }, owner: "daemon-a",
      claim_resolver: claim_resolver
    )
  end

  def entry(dir, name)
    {
      "name" => name,
      "project_id" => "#{name}-id",
      "path" => dir,
      "hive_state_path" => File.join(dir, ".hive-state")
    }
  end

  def enabled_cfg
    Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      "default_branch" => "main",
      "daemon" => { "enabled" => true },
      "refactor_patrol" => { "enabled" => true }
    )
  end

  def repository_identity(repository = "acme/demo", host = "github.com")
    { "repository" => repository, "host" => host }
  end

  def enqueue(store, job_id: "job-7", number: 7, merged_at: T0, registration: "demo")
    manifest = manifest(job_id: job_id, number: number, merged_at: merged_at, registration: registration)
    publish_manifest(store, manifest)
    enqueue_manifest(store,
      manifest,
      policy: { "discovery" => true, "auto_fix" => false, "issue_filing" => false },
      now: T0
    )
  end

  def enqueue_manifest(store, value, **options)
    capture = Hive::RefactorPatrol::TransitionGateway.capture_for_manifest(
      manifest: value,
      project_id: "demo-id",
      owner: "legacy",
      owner_epoch: 1,
      recorded_at: options.fetch(:now)
    )
    store.reserve_manifest_occurrence!(
      value, capture: capture, now: options.fetch(:now)
    )
    intent = Hive::Modules::Migration::EffectIntent.build(
      module_name: "architecture-patrol",
      occurrence_id: capture.occurrence_id,
      authority: capture.owner,
      owner_epoch: capture.owner_epoch,
      sink: "job",
      target: value.fetch("job_id"),
      idempotency_key: [
        value.fetch("job_id"),
        "enqueue",
        value.fetch("manifest_checksum")
      ].join(":"),
      capability: "filesystem_write",
      claim_generation: capture.owner_epoch,
      scope: { "job_id" => value.fetch("job_id") },
      created_at: capture.recorded_at
    )
    store.prepare_effect!(intent, now: options.fetch(:now))
    store.mark_dispatch_uncertain!(intent, now: options.fetch(:now))
    store.settle_effect!(
      intent,
      status: "committed",
      outcome: { "transition_status" => "applied" },
      now: options.fetch(:now)
    )
    store.enqueue_manifest!(
      value,
      occurrence_id: capture.occurrence_id,
      intake_transition_id: intent.intent_id,
      **options
    )
  end

  def install_recovery_protocol(store)
    generation = 0
    failure = nil
    store.define_singleton_method(:recovery_backoff) do |now:|
      {
        "generation" => generation,
        "failure" => failure,
        "blocked" =>
          failure &&
          now < Time.iso8601(failure.fetch("next_eligible_at"))
      }
    end
    store.define_singleton_method(
      :record_recovery_failure!
    ) do |operation:, occurrence_id: nil, job_id: nil, error:, now:|
      same = failure &&
             failure.fetch("operation") == operation &&
             failure["occurrence_id"] == occurrence_id &&
             failure["job_id"] == job_id
      count = same ? failure.fetch("failure_count") + 1 : 1
      interval = [ 60, 300, 900 ][[ count - 1, 2 ].min]
      generation += 1
      diagnostic =
        Hive::Modules::Migration::OccurrenceJournalState
        .normalize_error(error)
      failure = {
        "generation" => generation,
        "operation" => operation,
        "occurrence_id" => occurrence_id,
        "job_id" => job_id,
        "failure_count" => count,
        "next_eligible_at" => (now + interval).iso8601(6),
        "error_class" => diagnostic.fetch("error_class"),
        "error_message" => diagnostic.fetch("error_message")
      }
    end
    store.define_singleton_method(
      :clear_recovery_failure!
    ) do |expected_generation:|
      next false unless expected_generation == generation

      failure = nil
      true
    end
    store
  end

  def with_constant(owner, name, replacement)
    original = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, replacement)
    yield
  ensure
    owner.send(:remove_const, name) if
      owner.const_defined?(name, false)
    owner.const_set(name, original)
  end

  def manifest(job_id:, number:, merged_at:, registration:)
    payload = {
      "schema" => "hive-refactor-patrol-pr-manifest", "schema_version" => 2,
      "job_id" => job_id,
      "source" => {
        "url" => "https://github.com/acme/demo/pull/#{number}", "number" => number,
        "repository" => "acme/demo", "registration" => registration,
        "base_branch" => "main", "base_sha" => "base", "merge_sha" => "merge-#{number}",
        "merged_at" => merged_at.utc.iso8601
      },
      "files" => [ { "path" => "lib/demo.rb", "status" => "modified" } ],
      "changed_paths" => [ "lib/demo.rb" ]
    }
    payload.merge("manifest_checksum" => Hive::RefactorPatrol::PrManifest.checksum(payload))
  end

  def publish_manifest(store, manifest)
    root = File.join(File.dirname(store.root), "v2", "manifests")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "#{manifest.fetch('job_id')}.json"), JSON.generate(manifest))
  end

  def complete_zero_envelope(entry)
    aggregate = Hive::RefactorPatrol::JobStore.new(
      entry.fetch("path"),
      hive_state_path: entry.fetch("hive_state_path"),
      project: entry
    ).read_job("job-7")
    {
      "schema" => "hive-refactor-patrol", "schema_version" => 3, "ok" => true,
      "job_id" => "job-7", "project" => entry.fetch("name"), "project_root" => entry.fetch("path"),
      "dry_run" => false, "source_pr" => aggregate.fetch("source"), "analysis_sha" => "head",
      "complete" => true, "features_mapped" => 1,
      "accepted" => [], "flagged" => [], "suppressed" => [], "review_errors" => [],
      "feature_results" => [
        { "feature_id" => "checkout", "complete" => true, "thesis_ids" => [], "errors" => [] }
      ],
      "zero_reason" => "no_theses", "attempts" => [], "actions" => []
    }
  end

  def action_envelope(entry, aggregate)
    {
      "schema" => "hive-refactor-patrol", "schema_version" => 3, "ok" => true,
      "job_id" => aggregate.fetch("job_id"), "project" => entry.fetch("name"),
      "project_root" => entry.fetch("path"), "dry_run" => false,
      "source_pr" => aggregate.fetch("source"), "analysis_sha" => aggregate.fetch("analysis_sha"),
      "complete" => aggregate.fetch("complete"), "features_mapped" => 0,
      "accepted" => [], "flagged" => [], "suppressed" => [], "review_errors" => [],
      "feature_results" => [], "zero_reason" => nil, "attempts" => [], "actions" => []
    }
  end

  def write_action_job(dir, store)
    data = manifest(job_id: "action-job", number: 9, merged_at: T0, registration: "demo")
    publish_manifest(store, data)
    aggregate = enqueue_manifest(
      store,
      data,
      policy: {
        "discovery" => true,
        "auto_fix" => true,
        "issue_filing" => false
      },
      now: T0
    )
    snapshot = {
      "id" => "accepted", "feature_id" => "checkout", "feature" => "Checkout",
      "problem" => "Scattered policy", "cost" => "Repeated edits",
      "evidence" => [ { "file" => "lib/demo.rb", "claim" => "policy repeats" } ],
      "proposed_refactor" => "Consolidate policy",
      "feature_boundary" => { "owned_files" => [ "lib/demo.rb" ], "entrypoints" => [] },
      "feature_hotspot" => {}, "expected_leverage" => { "score" => 0.8 },
      "confidence" => "high", "risk" => { "flags" => [] },
      "required_validation" => { "commands" => [ "test" ] },
      "admissible" => true, "admissibility_reason" => "anchored",
      "follow_up_approval_state" => "pending", "fingerprint" => "fp-accepted"
    }
    store.write_job!(
      aggregate.merge(
        "analysis_sha" => "head",
        "state" => "classified", "complete" => false,
        "dispositions" => {
          "accepted" => [
            {
              "id" => "accepted", "feature_id" => "checkout", "fingerprint" => "fp-accepted",
              "score" => 0.8, "admissible" => true, "reasons" => [], "thesis" => snapshot
            }
          ],
          "flagged" => [], "suppressed" => []
        },
        "feature_results" => [], "review_errors" => [], "zero_reason" => nil,
        "attempts" => [], "actions" => [],
        "updated_at" => T0.iso8601
      )
    )
  end
end
