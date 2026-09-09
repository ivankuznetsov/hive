require "test_helper"
require "json"
require "hive/daemon/patrol_scheduler"
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

  def test_classification_is_supervised_claimed_once_and_terminal_skip_leaves_queue
    with_project do |dir, entry, store|
      classifier = Hive::RefactorPatrol::MergeClassifier.new(
        root: File.join(entry.fetch("hive_state_path"), "refactor_patrol", "v2", "merge-classifications"),
        decision_provider: lambda do |_prompt|
          {
            "decision" => "skip", "rationale" => "Not a feature",
            "evidence" => [ "Maintenance only" ], "model_receipt" => "fake:model"
          }
        end
      )
      record = classifier.hydrate(classification_snapshot, now: T0)
      options = {
        classifier_factory: ->(*) { classifier }
      }
      first = scheduler(entry, store, **options)
      second = scheduler(entry, store, **options)
      candidate = first.candidates(now: T0).fetch(0)

      dispatch = first.reserve(candidate, now: T0)
      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        second.reserve(candidate, now: T0)
      end
      assert_equal "classification_claim_unavailable", error.reason
      assert_includes dispatch.fetch(:command), "refactor-patrol-classify"
      refute_includes dispatch.fetch(:command), "read-only"

      classifier.run_occurrence(
        record.fetch("occurrence_id"),
        reservation_id: dispatch.dig(:dispatch_token, :reservation_id), now: T0 + 1
      )
      result = first.complete(
        dispatch_token: dispatch.fetch(:dispatch_token), exit_code: 0,
        envelope: { "decision" => "feature" }, now: T0 + 2
      )

      assert_equal :closed, result.fetch(:status)
      assert_empty first.candidates(now: T0 + 3)
    end
  end

  def test_oversized_feature_scope_splits_into_distinct_owners_and_binds_once
    with_project do |_dir, entry, store|
      classifier = Hive::RefactorPatrol::MergeClassifier.new(
        root: File.join(entry.fetch("hive_state_path"), "refactor_patrol", "v2", "merge-classifications"),
        decision_provider: lambda do |_prompt|
          {
            "decision" => "feature", "rationale" => "New capability",
            "evidence" => [ "Production behavior added" ], "model_receipt" => "fake:model"
          }
        end
      )
      paths = 513.times.map { |index| "lib/features/#{index}.rb" }
      record = classifier.call(classification_snapshot(paths: paths), now: T0)
      slice_mapper = Object.new
      slice_mapper.define_singleton_method(:call) do |analysis_sha:, paths:, **|
        Hive::RefactorPatrol::PostMergeSliceMapper::Mapping.new(
          analysis_sha: analysis_sha,
          path_mappings: paths.map do |path|
            { "path" => path, "slice_ids" => [ "shared-slice" ] }
          end
        )
      end
      active = scheduler(
        entry, store,
        cfg: enabled_cfg.merge(
          "execute" => { "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high" }
        ),
        classifier_factory: ->(*) { classifier },
        post_merge_slice_mapper: slice_mapper,
        checkout_guard_factory: ->(*) { Guard.new(sha: "c" * 40) },
      )

      first_candidate = active.candidates(now: T0 + 1).find do |item|
        item.fetch(:action_phase) == :post_merge
      end
      first_dispatch = active.reserve(first_candidate, now: T0 + 1)
      active.cancel(first_dispatch, reason: "test_next_chunk", now: T0 + 2)
      assert_nil classifier.fetch_occurrence(record.fetch("occurrence_id"))["materialization"]

      second_candidate = active.candidates(now: T0 + 3).find do |item|
        item.fetch(:action_phase) == :post_merge
      end
      second_dispatch = active.reserve(second_candidate, now: T0 + 3)

      jobs = store.jobs.sort_by { |job| job.fetch("created_at") }
      assert_equal 2, jobs.size
      assert_equal 2, jobs.map { |job| job.fetch("job_id") }.uniq.size
      assert_equal [ 512, 1 ], jobs.map { |job| job.dig("source", "changed_paths").size }
      assert_equal paths, jobs.flat_map { |job| job.dig("source", "changed_paths") }
      binding = classifier.fetch_occurrence(record.fetch("occurrence_id")).fetch("materialization")
      assert_equal jobs.map { |job| job.fetch("job_id") }, binding.fetch("job_ids")
      assert_equal 2, binding.fetch("job_ids").uniq.size
      active.cancel(second_dispatch, reason: "test_complete", now: T0 + 4)
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
        dir, hive_state_path: configured
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

  def test_candidate_pass_snapshots_registration_identity_once
    with_project do |_dir, entry, store|
      enqueue(store, job_id: "first", number: 7, merged_at: T0)
      enqueue(store, job_id: "second", number: 8, merged_at: T0 + 1)
      identity_calls = 0
      ownership = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { [ entry ] },
        config_loader: ->(_path) { enabled_cfg },
        identity_resolver: lambda do |_candidate, _cfg|
          identity_calls += 1
          repository_identity
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

      scheduler.reserve(candidates.first, now: T0 + 2)
      assert_equal 2, identity_calls, "reservation must re-resolve live repository identity"
    end
  end

  def test_duplicate_enabled_repository_registrations_block_with_both_identities_and_backoff
    with_tmp_dir do |root|
      first_dir = File.join(root, "first")
      second_dir = File.join(root, "second")
      [ first_dir, second_dir ].each { |dir| FileUtils.mkdir_p(dir) }
      entries = [ entry(first_dir, "one"), entry(second_dir, "two") ]
      first_store = Hive::RefactorPatrol::JobStore.new(
        first_dir
      )
      enqueue(first_store, registration: "one")
      stores = {
        first_dir => first_store,
        second_dir => Hive::RefactorPatrol::JobStore.new(
          second_dir
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
        first_dir
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
        first_dir
      )
      enqueue(first_store, registration: "one")
      stores = {
        first_dir => first_store,
        second_dir => Hive::RefactorPatrol::JobStore.new(
          second_dir
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
        assert_empty store.read_job("job-7").dig("dispositions", "fix")
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
      assert_empty scheduler.candidates(now: T0 + 3600), "completed zero must be terminal exactly once"
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
      scheduler.define_singleton_method(:checkpoint_discovery!) do |*, **|
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

  def test_completion_returns_retry_when_the_registry_lookup_raises_config_error
    with_project do |_dir, entry, store|
      enqueue(store)
      scheduler = scheduler(entry, store)
      dispatch = scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)
      broken_registry = lambda do
        raise Hive::ConfigError, "corrupt registry"
      end
      scheduler.instance_variable_set(:@registry, broken_registry)

      result = scheduler.complete(
        dispatch_token: dispatch.fetch(:dispatch_token),
        exit_code: 0,
        envelope: {},
        now: T0 + 1
      )

      assert_equal :retry, result.fetch(:status)
      assert_equal "job-7", result.fetch(:job_id)
      assert_equal "analyzing", store.read_job("job-7").fetch("state")

      recovered = scheduler(entry, store)
      assert_equal :closed, recovered.complete(
        dispatch_token: dispatch.fetch(:dispatch_token), exit_code: 0,
        envelope: complete_zero_envelope(entry), now: T0 + 2
      ).fetch(:status),
        "a healthy registry must still be able to settle the held claim"
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

  def test_restart_reclaims_a_dead_discovery_child_before_its_lease_expires
    with_project do |_dir, entry, store|
      enqueue(store)
      dead = store.claim_discovery!(
        "job-7", owner: "daemon-crashed", analysis_sha: "head",
        now: T0, lease_sec: 7200, owner_pid: 4242,
        owner_process_start_time: "boot-dead"
      )
      store.attach_discovery_process!(
        dead, pid: 4242, process_start_time: "boot-dead", pgid: 4242,
        now: T0 + 1, lease_sec: 7200
      )
      probes = []
      scheduler = scheduler(
        entry, store,
        claim_resolver: ->(_claim) { :resolved },
        claim_liveness_resolver: lambda do |claim|
          probes << claim
          :resolved
        end
      )

      candidate = scheduler.candidates(now: T0 + 60).fetch(0)
      dispatch = scheduler.reserve(candidate, now: T0 + 60)

      assert_equal "job-7", dispatch.dig(:dispatch_token, :job_id)
      assert_equal dead.fetch(:generation) + 1,
                   dispatch.dig(:dispatch_token, :generation)
      assert probes.any? { |claim| claim["pid"] == 4242 }
      attempts = store.read_job("job-7").fetch("attempts")
      assert_equal "superseded", attempts[-2].fetch("state")
      assert_equal "inactive_claim_resolved", attempts[-2].fetch("outcome")
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

  def test_review_resource_deferral_uses_the_shared_one_hour_retry
    %w[token_limit turn_limit agent_in_flight].each do |reason|
      with_project do |_dir, entry, store|
        enqueue(store)
        scheduler = scheduler(entry, store)
        dispatch = scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)
        scheduler.spawned(dispatch, pid: 1234, process_start_time: "boot", pgid: 1234, now: T0 + 1)
        error = {
          "feature_id" => "checkout", "error" => "agent_failed",
          "message" => "agent exceeded runaway ceiling",
          "details" => {
            "resource_exhaustion" => {
              "reason" => reason, "limit" => 100_000_000,
              "observed" => 100_000_001
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
        assert_empty scheduler.candidates(now: T0 + 3601), reason
        assert_equal [ "job-7" ],
                     scheduler.candidates(now: T0 + 3602).map { |item| item.fetch(:job_id) },
                     reason
      end
    end
  end

  def test_daily_launch_limit_defers_review_until_the_next_utc_day
    with_project do |_dir, entry, store|
      enqueue(store)
      scheduler = scheduler(entry, store)
      dispatch = scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)
      scheduler.spawned(dispatch, pid: 1234, process_start_time: "boot", pgid: 1234, now: T0 + 1)
      error = {
        "feature_id" => "checkout", "error" => "agent_failed",
        "message" => "daily launch limit reached",
        "details" => {
          "resource_exhaustion" => {
            "reason" => "daily_agent_spawn_limit", "limit" => 8, "observed" => 8
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

      assert_equal :retry, result.fetch(:status)
      assert_empty scheduler.candidates(now: T0 + 43_199)
      assert_equal [ "job-7" ],
                   scheduler.candidates(now: T0 + 43_200).map { |item| item.fetch(:job_id) }
    end
  end

  def test_idle_discovery_does_not_query_launch_capacity
    with_project do |_dir, entry, store|
      subject = scheduler(entry, store)
      unexpected = lambda do |*, **|
        raise "idle discovery must not construct a launch budget"
      end

      with_replaced_singleton_method(
        Hive::Patrol::LaunchBudget, :new, unexpected
      ) do
        assert_empty subject.candidates(now: T0)
      end
    end
  end

  def test_scheduled_discovery_exhaustion_does_not_block_post_merge_candidates
    old_database = Hive::UsageDb.database
    with_project do |dir, entry, store|
      database = prepare_runtime_project(
        state_home: tracked_tmp_dir("hive-test-refactor-patrol-runtime"),
        name: entry.fetch("name"), path: entry.fetch("path"),
        state_root_path: entry.fetch("hive_state_path"),
        project_id: entry.fetch("project_id")
      )
      (@hive_test_runtime_databases ||= []) << database
      Hive::UsageDb.database = database
      8.times do |index|
        stage = index.even? ? "patrol-review" : "refactor-patrol-review"
        Hive::UsageDb.record!(
          agent: "codex", model: nil, project_slug: entry.fetch("name"),
          task_slug: stage, stage: stage,
          started_at: T0, ended_at: T0, input: 1, output: 1, cached: 0
        )
      end
      enqueue(store)
      scheduler = scheduler(entry, store)

      assert_equal [ "job-7" ],
                   scheduler.candidates(now: T0).map { |item| item.fetch(:job_id) }
    end
  ensure
    Hive::UsageDb.database = old_database
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

  def test_non_coding_default_workflow_blocks_discovery_and_reservation
    with_project do |_dir, entry, store|
      enqueue(store)
      cfg = enabled_cfg.merge("default_workflow" => "content")
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

  def test_source_missing_from_trunk_is_terminalized_without_retry_loop
    with_project do |_dir, entry, store|
      enqueue(store)
      guard_calls = 0
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { repository_identity },
        checkout_guard_factory: ->(*) {
          Object.new.tap do |guard|
            guard.define_singleton_method(:validate_and_snapshot!) do |merge_sha:, **|
              guard_calls += 1
              raise Hive::RefactorPatrol::CheckoutGuard::SourceNoLongerOnTrunk.new(
                merge_sha: merge_sha,
                trunk_sha: "head"
              )
            end
          end
        }, owner: "daemon-a"
      )

      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)
      end

      assert_equal "source_no_longer_on_trunk", error.reason
      assert_equal 1, guard_calls
      retired = store.read_job("job-7")
      assert retired.fetch("complete")
      assert_equal "source_no_longer_on_trunk",
                   retired.fetch("attempts").last.fetch("reason")
      assert_empty scheduler.candidates(now: T0 + 10_000)
      assert_equal 1, guard_calls, "a retired source must never re-enter checkout validation"
    end
  end

  def test_dry_run_reports_obsolete_source_without_retiring_the_job
    with_project do |_dir, entry, store|
      enqueue(store)
      before = store.read_job("job-7")
      scheduler = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { enabled_cfg },
        job_store_factory: ->(_path) { store },
        repository_resolver: ->(_entry, _cfg) { repository_identity },
        checkout_guard_factory: ->(*) {
          Object.new.tap do |guard|
            guard.define_singleton_method(:validate_and_snapshot!) do |merge_sha:, **|
              raise Hive::RefactorPatrol::CheckoutGuard::SourceNoLongerOnTrunk.new(
                merge_sha: merge_sha,
                trunk_sha: "head"
              )
            end
          end
        },
        owner: "daemon-a", dry_run: true
      )

      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        scheduler.reserve(scheduler.candidates(now: T0).first, now: T0)
      end

      assert_equal "source_no_longer_on_trunk", error.reason
      assert_equal "retired", error.evidence.fetch("retirement")
      assert_equal before, store.read_job("job-7")
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
        "dispositions" => { "fix" => [], "discuss" => [], "dismiss" => [] },
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

  def test_classification_work_handles_due_retry_and_isolates_corrupt_records
    with_tmp_dir do |dir|
      configured_entry = entry(dir, "demo").merge("_refactor_patrol_cfg" => enabled_cfg)
      records = [
        { "occurrence_id" => "due", "status" => "retry_wait", "retry_at" => T0.iso8601 },
        { "occurrence_id" => "later", "status" => "retry_wait", "retry_at" => (T0 + 60).iso8601 },
        { "occurrence_id" => "bad", "status" => "retry_wait", "retry_at" => "never" }
      ]
      classifier = Object.new
      classifier.define_singleton_method(:eligible_records) { |**| records }
      batches = Object.new
      batches.define_singleton_method(:unclaimed_occurrence_ids) { |_records| [] }
      active = scheduler(
        configured_entry, Hive::RefactorPatrol::JobStore.new(dir),
        classifier_factory: ->(*) { classifier },
        post_merge_batch_store_factory: ->(*) { batches }
      )

      work = active.send(:classification_work, configured_entry, nil, T0)

      assert_equal [ "due" ], work.map { |item| item.dig(:classification, "occurrence_id") }
      event = active.drain_events.fetch(0)
      assert_equal "classification_admission_failed", event.fetch(:reason)
      assert_equal "bad", event.fetch(:occurrence_id)
    end
  end

  def test_classification_completion_maps_all_terminal_states_and_failures
    with_tmp_dir do |dir|
      configured_entry = entry(dir, "demo").merge("_refactor_patrol_cfg" => enabled_cfg)
      record = nil
      classifier = Object.new
      classifier.define_singleton_method(:fetch_occurrence) { |_id| record }
      classifier.define_singleton_method(:release_claim!) do |_id, **|
        record = record.merge("claim" => nil)
      end
      active = scheduler(
        configured_entry, Hive::RefactorPatrol::JobStore.new(dir),
        classifier_factory: ->(*) { classifier }
      )
      token = {
        registration: "demo", classification_occurrence_id: "occurrence-1",
        reservation_id: "reservation-1"
      }

      assert_equal :blocked, active.send(:complete_classification, token, 0, T0).fetch(:status)
      {
        "feature" => :classified, "skip" => :closed,
        "blocked" => :blocked, "retry_wait" => :retry
      }.each do |status, expected|
        record = {
          "occurrence_id" => "occurrence-1", "status" => status,
          "reason" => status, "claim" => { "reservation_id" => "reservation-1" }
        }
        assert_equal expected,
                     active.send(:complete_classification, token, 0, T0).fetch(:status)
      end

      classifier.define_singleton_method(:fetch_occurrence) { |_id| raise "corrupt" }
      failure = active.send(:complete_classification, token, 0, T0)
      assert_equal "classification_completion_failed", failure.fetch(:reason)
    end
  end

  def test_classification_cancel_releases_claim_and_completion_summary_is_bounded
    with_tmp_dir do |dir|
      configured_entry = entry(dir, "demo").merge("_refactor_patrol_cfg" => enabled_cfg)
      releases = []
      classifier = Object.new
      classifier.define_singleton_method(:release_claim!) do |occurrence_id, **arguments|
        releases << [ occurrence_id, arguments ]
      end
      active = scheduler(
        configured_entry, Hive::RefactorPatrol::JobStore.new(dir),
        classifier_factory: ->(*) { classifier }
      )
      dispatch = {
        entry: configured_entry,
        dispatch_token: {
          phase: :classification, classification_occurrence_id: "occurrence-1",
          reservation_id: "reservation-1"
        }
      }

      assert_same dispatch, active.cancel(dispatch, reason: "shutdown", now: T0)
      assert_equal "occurrence-1", releases.fetch(0).fetch(0)

      aggregate = {
        "source" => { "number" => 7, "url" => "https://example.test/7" },
        "dispositions" => { "fix" => [], "discuss" => [], "dismiss" => [] },
        "actions" => [
          { "canonical_action_id" => "done", "terminal" => true, "outcome" => "complete" },
          { "canonical_action_id" => "pending", "terminal" => false, "outcome" => nil }
        ]
      }
      summary = active.send(
        :completion_result, :action_pending, { job_id: "job-1" }, {}, aggregate: aggregate
      )
      assert_equal 1, summary.fetch(:terminal_action_count)
      assert_equal [ "pending" ], summary.fetch(:pending_action_ids)
      assert_equal({ "done" => "complete" }, summary.fetch(:action_outcomes))
      assert_equal Time.at(0).utc, active.send(:parse_time, "not-a-time")
    end
  end

  def test_candidate_scan_contains_store_failure_and_supports_a_plain_ownership_resolver
    with_project do |_dir, entry, store|
      enqueue(store)
      ownership = lambda do |**|
        Hive::RefactorPatrol::RepositoryOwnership::Decision.new(
          authority: :full, reason: "unique_owner", evidence: []
        )
      end
      active = scheduler(entry, store, repository_ownership: ownership)
      assert_equal [ "job-7" ], active.candidates(now: T0).map { |row| row.fetch(:job_id) }

      broken = Hive::Daemon::RefactorPatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(*) { enabled_cfg },
        job_store_factory: ->(*) { raise "store unavailable" },
        repository_ownership: ownership
      )
      assert_empty broken.candidates(now: T0)
      assert_includes broken.drain_events.map { |event| event.fetch(:reason) },
                      "recovery_state_unavailable"
    end
  end

  def test_default_classifier_provider_and_batch_recovery_boundaries
    with_tmp_dir do |dir|
      configured_entry = entry(dir, "demo").merge("_refactor_patrol_cfg" => enabled_cfg)
      active = scheduler(configured_entry, Hive::RefactorPatrol::JobStore.new(dir))
      classifier = active.send(:classifier_for, configured_entry)
      runner = Object.new
      runner.define_singleton_method(:call) { |prompt| { "prompt" => prompt } }
      result = with_replaced_singleton_method(
        Hive::RefactorPatrol::MergeClassifierRunner, :new, ->(**) { runner }
      ) do
        classifier.instance_variable_get(:@decision_provider).call("classify")
      end
      assert_equal "classify", result.fetch("prompt")

      batches = Object.new
      batches.define_singleton_method(:pending) do |**|
        [ { "batch_id" => "ok" }, { "batch_id" => "broken" } ]
      end
      active.define_singleton_method(:post_merge_batch_store_for) { |_| batches }
      active.define_singleton_method(:materialize_batch_record) do |_entry, _store, batch, _now|
        raise "cannot materialize" if batch.fetch("batch_id") == "broken"
        true
      end
      active.send(:recover_post_merge_batches, configured_entry, Object.new, T0)
      event = active.drain_events.fetch(0)
      assert_equal "post_merge_batch_recovery_failed", event.fetch(:reason)
      assert_equal "broken", event.fetch(:batch_id)
    end
  end

  def test_batch_materialization_uses_live_config_and_injected_resolver
    with_tmp_dir do |dir|
      raw_entry = entry(dir, "demo")
      resolver_calls = []
      resolver = Object.new
      resolver.define_singleton_method(:materialize_batch) { |*| raise "stop after resolution" }
      active = scheduler(
        raw_entry, Hive::RefactorPatrol::JobStore.new(dir),
        manifest_resolver_factory: lambda do |candidate, cfg|
          resolver_calls << [ candidate, cfg ]
          resolver
        end,
        classifier_factory: ->(*) { Object.new }
      )

      assert_raises(RuntimeError) do
        active.send(:materialize_batch_record, raw_entry, Object.new, { "members" => [] }, T0)
      end
      assert_equal "main", resolver_calls.fetch(0).fetch(1).fetch("default_branch")
    end
  end

  def test_post_merge_reservation_revalidates_and_contains_recovery_failures
    with_tmp_dir do |dir|
      configured_entry = entry(dir, "demo").merge("_refactor_patrol_cfg" => enabled_cfg)
      store = Hive::RefactorPatrol::JobStore.new(dir)
      record = {
        "occurrence_id" => "occurrence-1", "status" => "feature",
        "decision" => "feature", "materialization" => nil,
        "snapshot" => classification_snapshot
      }
      candidate = { classification_occurrence_id: "occurrence-1" }
      classifier = Object.new
      current = record
      classifier.define_singleton_method(:fetch_occurrence) { |_| current }
      mapper = Object.new
      mapper.define_singleton_method(:call) do |paths:, analysis_sha:, **|
        Hive::RefactorPatrol::PostMergeSliceMapper::Mapping.new(
          analysis_sha: analysis_sha,
          path_mappings: paths.map { |path| { "path" => path, "slice_ids" => [ "slice" ] } }
        )
      end
      active = scheduler(
        configured_entry, store, classifier_factory: ->(*) { classifier },
        post_merge_slice_mapper: mapper,
        checkout_guard_factory: ->(*) { Guard.new(sha: "c" * 40) }
      )
      active.define_singleton_method(:post_merge_candidates) { |*| [ record ] }

      current = nil
      changed = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        active.send(:reserve_post_merge, candidate, configured_entry, enabled_cfg, T0)
      end
      assert_equal "post_merge_classification_changed", changed.reason

      fetches = 0
      classifier.define_singleton_method(:fetch_occurrence) do |_|
        fetches += 1
        fetches == 1 ? record : nil
      end
      stale_freshness = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        active.send(:reserve_post_merge, candidate, configured_entry, enabled_cfg, T0)
      end
      assert_equal "post_merge_classification_changed", stale_freshness.reason

      current = record
      classifier.define_singleton_method(:fetch_occurrence) { |_| current }
      batch_store = Object.new
      batch_store.define_singleton_method(:claim!) do |**|
        raise Hive::RefactorPatrol::PostMergeBatchStore::Conflict, "claimed"
      end
      batch_store.define_singleton_method(:batches_for_occurrence) { |_| [] }
      active.define_singleton_method(:post_merge_batch_store_for) { |_| batch_store }
      missing = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        active.send(:reserve_post_merge, candidate, configured_entry, enabled_cfg, T0)
      end
      assert_equal "post_merge_batch_claim_changed", missing.reason

      batch = { "status" => "claimed", "analysis_sha" => "c" * 40 }
      batch_store.define_singleton_method(:batches_for_occurrence) { |_| [ batch ] }
      aggregate = {
        "job_id" => "job-1",
        "source" => { "number" => 7, "url" => "https://github.com/acme/demo/pull/7" }
      }
      active.define_singleton_method(:materialize_batch_record) do |*|
        { aggregate: aggregate }
      end
      active.define_singleton_method(:reserve) { |*args, **kwargs| :recovered }
      assert_equal :recovered,
                   active.send(:reserve_post_merge, candidate, configured_entry, enabled_cfg, T0)

      active.instance_variable_set(
        :@checkout_guard_factory,
        lambda do |*|
          Object.new.tap do |guard|
            guard.define_singleton_method(:validate_and_snapshot!) do |merge_sha:, **|
              raise Hive::RefactorPatrol::CheckoutGuard::SourceNoLongerOnTrunk.new(
                merge_sha: merge_sha, trunk_sha: "f" * 40
              )
            end
          end
        end
      )
      stale = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        active.send(:reserve_post_merge, candidate, configured_entry, enabled_cfg, T0)
      end
      assert_equal "source_no_longer_on_trunk", stale.reason

      active.instance_variable_set(
        :@checkout_guard_factory, ->(*) { raise Hive::GitError, "offline" }
      )
      failed = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        active.send(:reserve_post_merge, candidate, configured_entry, enabled_cfg, T0)
      end
      assert_equal "post_merge_batch_materialization_failed", failed.reason
    end
  end

  def test_discovery_retirement_transition_failure_is_contained
    with_project do |_dir, entry, store|
      enqueue(store)
      active = scheduler(
        entry, store,
        checkout_guard_factory: lambda do |*|
          Object.new.tap do |guard|
            guard.define_singleton_method(:validate_and_snapshot!) do |merge_sha:, **|
              raise Hive::RefactorPatrol::CheckoutGuard::SourceNoLongerOnTrunk.new(
                merge_sha: merge_sha, trunk_sha: "f" * 40
              )
            end
          end
        end
      )
      transitions = Object.new
      transitions.define_singleton_method(:retire) { |**| :retry }
      transitions.define_singleton_method(:block) { |**| true }
      active.instance_variable_set(:@discovery_transitions, transitions)

      error = assert_raises(Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked) do
        active.reserve(active.candidates(now: T0).fetch(0), now: T0)
      end
      assert_equal "checkout_guard", error.reason
    end
  end

  private

  def with_project
    with_tmp_dir do |dir|
      entry = entry(dir, "demo")
      yield(
        dir,
        entry,
        Hive::RefactorPatrol::JobStore.new(dir)
      )
    end
  end

  def scheduler(entry, store, claim_resolver: ->(_attempt) { :resolved },
                cfg: enabled_cfg,
                claim_liveness_resolver: claim_resolver,
                checkout_guard_factory: ->(*) { Guard.new }, **options)
    Hive::Daemon::RefactorPatrolScheduler.new(
      registry: -> { [ entry ] }, config_loader: ->(_path) { cfg },
      job_store_factory: ->(_path) { store },
      repository_resolver: ->(_entry, _cfg) { repository_identity },
      checkout_guard_factory: checkout_guard_factory, owner: "daemon-a",
      claim_resolver: claim_resolver,
      claim_liveness_resolver: claim_liveness_resolver,
      **options
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

  def classification_snapshot(number: 7, paths: [ "lib/feature.rb" ], merged_at: T0)
    {
      "repository" => "acme/demo", "number" => number,
      "url" => "https://github.com/acme/demo/pull/#{number}",
      "base_branch" => "main", "base_sha" => "a" * 40,
      "merge_sha" => format("%040x", number), "merged_at" => merged_at.iso8601,
      "target_head" => "c" * 40, "title" => "Add feature", "body" => "Capability",
      "labels" => [ "feature" ], "author" => "dev",
      "changed_paths" => paths,
      "files" => paths.map do |path|
        { "path" => path, "status" => "modified", "patch" => "@@ -1 +1 @@" }
      end,
      "publication_provenance" => { "kind" => "none", "marker" => nil }
    }
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
    Hive::RefactorPatrol::ArchitectureIntakeTransitions.new.enqueue(
      entry: nil,
      store: store,
      manifest: value,
      policy: options.fetch(:policy),
      now: options.fetch(:now),
      dry_run: options.fetch(:dry_run, false)
    )
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
      hive_state_path: entry.fetch("hive_state_path")
    ).read_job("job-7")
    {
      "schema" => "hive-refactor-patrol", "schema_version" => 4, "ok" => true,
      "job_id" => "job-7", "project" => entry.fetch("name"), "project_root" => entry.fetch("path"),
      "dry_run" => false, "source_pr" => aggregate.fetch("source"), "analysis_sha" => "head",
      "complete" => true, "features_mapped" => 1,
      "fix" => [], "discuss" => [], "dismiss" => [], "review_errors" => [],
      "feature_results" => [
        { "feature_id" => "checkout", "complete" => true, "thesis_ids" => [], "errors" => [] }
      ],
      "zero_reason" => "no_theses", "attempts" => [], "actions" => []
    }
  end
end
