require "test_helper"
require "hive/refactor_patrol/job_store"

class RefactorPatrolJobStoreTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 10, 12, 0, 0)

  def test_writes_and_strictly_reads_authoritative_job_aggregate
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      aggregate = job

      assert_equal aggregate, store.write_job!(aggregate)
      assert_equal aggregate, store.read_job("job-1")
      assert_equal File.join(dir, ".hive-state", "refactor_patrol", "v2"), store.root
      assert_empty Dir.glob(File.join(store.root, "jobs", ".*.tmp.*"))
    end
  end

  def test_dry_run_validates_but_persists_nothing
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)

      assert_equal job, store.write_job!(job, dry_run: true)
      refute Dir.exist?(store.root)
    end
  end

  def test_corrupt_newer_and_inconsistent_jobs_fail_visibly_without_rewrite
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      jobs_dir = File.join(store.root, "jobs")
      FileUtils.mkdir_p(jobs_dir)

      corrupt_path = File.join(jobs_dir, "corrupt.json")
      File.write(corrupt_path, "{")
      corrupt_bytes = File.binread(corrupt_path)
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) { store.read_job("corrupt") }
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        store.write_job!(
          job("job_id" => "corrupt", "actions" => [ action.merge("owner_job_id" => "corrupt") ])
        )
      end
      assert_equal corrupt_bytes, File.binread(corrupt_path)

      newer_path = File.join(jobs_dir, "newer.json")
      File.write(newer_path, JSON.generate(job("job_id" => "newer", "schema_version" => 99)))
      newer_bytes = File.binread(newer_path)
      assert_raises(Hive::RefactorPatrol::JobStore::UnsupportedVersion) { store.read_job("newer") }
      assert_equal newer_bytes, File.binread(newer_path)

      inconsistent_path = File.join(jobs_dir, "inconsistent.json")
      File.write(inconsistent_path, JSON.generate(job("job_id" => "different")))
      inconsistent_bytes = File.binread(inconsistent_path)
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) { store.read_job("inconsistent") }
      assert_equal inconsistent_bytes, File.binread(inconsistent_path)
    end
  end

  def test_rebuilds_derived_indexes_after_deletion_or_corruption
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.write_job!(job)

      first = store.rebuild_indexes!
      assert_equal "job-1", first.fetch("actions").fetch("actions").fetch("fix-fp-accepted").fetch("owner_job_id")
      assert_equal "accepted", first.fetch("fingerprints").fetch("fingerprints").fetch("fp-accepted")
                                         .fetch("occurrences").first.fetch("disposition")
      refute first.fetch("actions").fetch("actions").fetch("fix-fp-accepted").key?("receipts")

      FileUtils.rm_f(store.action_index_path)
      File.write(store.fingerprint_index_path, "{")

      assert_equal first.fetch("actions"), store.action_index
      assert_equal first.fetch("fingerprints"), store.fingerprint_index
    end
  end

  def test_canonical_receipts_belong_only_to_first_owner_job
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.write_job!(job)
      linked = job(
        "job_id" => "job-2",
        "source" => source("number" => 8, "merge_sha" => "d" * 40),
        "dispositions" => {
          "accepted" => [ disposition("accepted-2", "fp-accepted") ],
          "flagged" => [],
          "suppressed" => []
        },
        "actions" => [ action.merge("thesis_id" => "accepted-2", "owner_job_id" => "job-1", "receipts" => {}) ]
      )
      store.write_job!(linked)

      rebuilt = store.rebuild_indexes!
      assert_equal "job-1", rebuilt.fetch("actions").fetch("actions").fetch("fix-fp-accepted").fetch("owner_job_id")

      bad_link = linked.merge(
        "job_id" => "job-3",
        "actions" => [ action.merge("owner_job_id" => "job-1", "receipts" => { "pr_url" => "https://example.test/duplicate" }) ]
      )
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) { store.write_job!(bad_link) }
    end
  end

  def test_v2_writes_leave_legacy_state_byte_identical
    with_tmp_dir do |dir|
      legacy_dir = File.join(dir, ".hive-state", "refactor_patrol")
      FileUtils.mkdir_p(legacy_dir)
      legacy_path = File.join(legacy_dir, "fingerprints.json")
      File.binwrite(legacy_path, "{\n  \"legacy\": true\n}\n")
      before = File.binread(legacy_path)

      Hive::RefactorPatrol::JobStore.new(dir).write_job!(job)

      assert_equal before, File.binread(legacy_path)
    end
  end

  def test_existing_analysis_disposition_is_immutable_while_actions_are_separate
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      partial = job(
        "state" => "classified",
        "complete" => false,
        "actions" => [],
        "attempts" => [ { "number" => 1, "outcome" => "classified" } ]
      )
      store.write_job!(partial)

      acting = store.initialize_actions!(
        "job-1",
        specifications: [ { "thesis_id" => "accepted", "kind" => "fix" } ],
        now: Time.iso8601("2026-07-10T10:02:00Z")
      )
      assert_equal "accepted", store.read_job("job-1").dig("dispositions", "accepted", 0, "id")

      reclassified = acting.merge(
        "dispositions" => {
          "accepted" => [],
          "flagged" => [ disposition("accepted", "fp-accepted").merge("reasons" => [ "validation_failed" ]) ],
          "suppressed" => []
        }
      )
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) { store.write_job!(reclassified) }
      assert_equal "accepted", store.read_job("job-1").dig("dispositions", "accepted", 0, "id")
    end
  end

  def test_manifest_intake_creates_one_stable_queued_job
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)

      created = store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      duplicate = store.enqueue_manifest!(
        manifest,
        policy: intake_policy.merge("auto_fix" => true),
        now: T0 + 60
      )

      assert_equal "pr-7-stable", created.fetch("job_id")
      assert_equal "queued", created.fetch("state")
      assert_nil created.fetch("analysis_sha")
      assert_equal manifest.fetch("manifest_checksum"), created.dig("source", "manifest_checksum")
      assert_equal created, duplicate, "duplicate producers must preserve the first policy snapshot and bytes"
      assert_equal [ "pr-7-stable" ], store.jobs.map { |entry| entry.fetch("job_id") }
    end
  end

  def test_manifest_intake_rejects_divergent_source_without_overwrite
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      original = store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      path = File.join(store.root, "jobs", "pr-7-stable.json")
      bytes = File.binread(path)
      divergent = manifest.merge(
        "changed_paths" => [ "lib/other.rb" ],
        "manifest_checksum" => "f" * 64
      )

      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.enqueue_manifest!(divergent, policy: intake_policy, now: T0 + 60)
      end
      assert_equal original, store.read_job("pr-7-stable")
      assert_equal bytes, File.binread(path)
      quarantine = Dir.glob(File.join(store.root, "quarantine", "jobs", "*.json"))
      assert_equal 1, quarantine.size
      assert_equal "divergent_job_source", JSON.parse(File.read(quarantine.first)).fetch("reason")
    end
  end

  def test_eligible_jobs_filters_backoff_per_job_without_starving_later_work
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      first_manifest = manifest(
        "source" => manifest.fetch("source").merge("merged_at" => "2026-07-10T13:00:00+01:00")
      )
      first = store.enqueue_manifest!(first_manifest, policy: intake_policy, now: T0)
      second_manifest = manifest(
        "job_id" => "pr-8-stable",
        "source" => manifest.fetch("source").merge(
          "number" => 8,
          "url" => "https://github.com/acme/demo/pull/8",
          "merge_sha" => "d" * 40,
          "merged_at" => "2026-07-10T12:01:00Z"
        ),
        "manifest_checksum" => "e" * 64
      )
      second = store.enqueue_manifest!(second_manifest, policy: intake_policy, now: T0 + 60)
      store.write_job!(
        first.merge(
          "state" => "blocked",
          "attempts" => [ { "next_eligible_at" => (T0 + 3600).iso8601 } ],
          "updated_at" => (T0 + 120).iso8601
        )
      )

      assert_equal [ second.fetch("job_id") ],
                   store.eligible_jobs(now: T0 + 180).map { |entry| entry.fetch("job_id") }
      assert_equal %w[pr-7-stable pr-8-stable],
                   store.eligible_jobs(now: T0 + 7200).map { |entry| entry.fetch("job_id") }
    end
  end

  def test_discovery_claim_is_fenced_and_only_exact_owner_generation_can_checkpoint
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)

      token = store.claim_discovery!(
        "pr-7-stable", owner: "daemon-a", analysis_sha: "c" * 40,
        now: T0, lease_sec: 60
      )
      store.attach_discovery_process!(
        token, pid: 1234, process_start_time: "boot-1", pgid: 1234, now: T0 + 1
      )

      stale = token.merge(generation: token.fetch(:generation) + 1)
      assert_raises(Hive::RefactorPatrol::JobStore::StaleClaim) do
        store.checkpoint_discovery!(stale, envelope: complete_zero_envelope(dir), now: T0 + 2)
      end
      assert_empty store.read_job("pr-7-stable").dig("dispositions", "accepted")

      completed = store.checkpoint_discovery!(token, envelope: complete_zero_envelope(dir), now: T0 + 3)
      assert completed.fetch("complete")
      assert_equal "no_theses", completed.fetch("zero_reason")
      assert_raises(Hive::RefactorPatrol::JobStore::StaleClaim) do
        store.checkpoint_discovery!(token, envelope: complete_zero_envelope(dir), now: T0 + 4)
      end
    end
  end

  def test_expired_claim_reclaims_only_after_process_identity_is_resolved
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      first = store.claim_discovery!(
        "pr-7-stable", owner: "daemon-a", analysis_sha: "c" * 40,
        now: T0, lease_sec: 10
      )
      store.attach_discovery_process!(
        first, pid: 1234, process_start_time: "boot-1", pgid: 1234, now: T0 + 1
      )

      unresolved = store.claim_discovery!(
        "pr-7-stable", owner: "daemon-b", analysis_sha: "c" * 40,
        now: T0 + 20, lease_sec: 10, claim_resolver: ->(_attempt) { :unresolved }
      )
      assert_nil unresolved

      reclaimed = store.claim_discovery!(
        "pr-7-stable", owner: "daemon-b", analysis_sha: "c" * 40,
        now: T0 + 20, lease_sec: 10, claim_resolver: ->(_attempt) { :resolved }
      )
      assert_equal first.fetch(:generation) + 1, reclaimed.fetch(:generation)
      assert_equal "daemon-b", reclaimed.fetch(:owner)
    end
  end

  def test_discovery_heartbeat_renews_only_the_live_exact_generation
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      token = store.claim_discovery!(
        "pr-7-stable", owner: "daemon-a", analysis_sha: "c" * 40,
        now: T0, lease_sec: 60, owner_pid: 1234,
        owner_process_start_time: "boot-1"
      )

      renewed = store.renew_discovery_claim!(
        token, now: T0 + 50, lease_sec: 60,
        claim_resolver: ->(_claim) { :unresolved }
      )
      attempt = renewed.fetch("attempts").last
      assert_equal (T0 + 50).iso8601, attempt.fetch("heartbeat_at")
      assert_equal (T0 + 110).iso8601, attempt.fetch("expires_at")
      assert_nil store.claim_discovery!(
        "pr-7-stable", owner: "daemon-b", analysis_sha: "c" * 40,
        now: T0 + 61, lease_sec: 60, claim_resolver: ->(_claim) { :resolved }
      )

      assert_raises(Hive::RefactorPatrol::JobStore::StaleClaim) do
        store.renew_discovery_claim!(
          token, now: T0 + 111, lease_sec: 60,
          claim_resolver: ->(_claim) { :unresolved }
        )
      end
      replacement = store.claim_discovery!(
        "pr-7-stable", owner: "daemon-b", analysis_sha: "c" * 40,
        now: T0 + 111, lease_sec: 60, claim_resolver: ->(_claim) { :resolved }
      )
      refute_nil replacement
      assert_raises(Hive::RefactorPatrol::JobStore::StaleClaim) do
        store.renew_discovery_claim!(
          token, now: T0 + 112, lease_sec: 60,
          claim_resolver: ->(_claim) { :unresolved }
        )
      end
    end
  end

  def test_claim_heartbeat_rejects_dead_owner_and_matches_pid_start_time
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      token = store.claim_discovery!(
        "pr-7-stable", owner: "daemon-a", analysis_sha: "c" * 40,
        now: T0, lease_sec: 60, owner_pid: 1234,
        owner_process_start_time: "boot-1"
      )

      assert_empty store.active_claim_tokens_for_process(
        "pr-7-stable", pid: 1234, process_start_time: "reused-pid"
      )
      assert_equal [ :discovery ], store.active_claim_tokens_for_process(
        "pr-7-stable", pid: 1234, process_start_time: "boot-1"
      ).map { |claim| claim.fetch(:kind) }
      assert_raises(Hive::RefactorPatrol::JobStore::StaleClaim) do
        store.renew_discovery_claim!(
          token, now: T0 + 30, lease_sec: 60,
          claim_resolver: ->(_claim) { :resolved }
        )
      end
      assert_equal (T0 + 60).iso8601,
                   store.read_job("pr-7-stable").fetch("attempts").last.fetch("expires_at")
    end
  end

  def test_release_records_durable_retry_without_disposition_checkpoint
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      token = store.claim_discovery!(
        "pr-7-stable", owner: "daemon-a", analysis_sha: "c" * 40,
        now: T0, lease_sec: 60
      )

      released = store.release_discovery!(token, reason: "malformed_envelope", now: T0 + 1, backoff_sec: 60)

      assert_equal "blocked", released.fetch("state")
      assert_equal (T0 + 61).iso8601, released.fetch("attempts").last.fetch("next_eligible_at")
      assert_empty released.dig("dispositions", "accepted")
      assert_empty store.eligible_jobs(now: T0 + 60)
      assert_equal [ "pr-7-stable" ], store.eligible_jobs(now: T0 + 61).map { |item| item.fetch("job_id") }
    end
  end

  def test_partial_checkpoint_preserves_completed_features_and_retries_only_incomplete_work
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      token = store.claim_discovery!(
        "pr-7-stable", owner: "daemon-a", analysis_sha: "c" * 40,
        now: T0, lease_sec: 60
      )
      accepted = disposition("checkout-thesis", "fp-checkout").merge(
        "thesis" => thesis_snapshot("checkout-thesis", "fp-checkout")
      )
      error = { "feature_id" => "search", "error" => "agent_failed", "message" => "timeout" }
      partial = complete_zero_envelope(dir).merge(
        "complete" => false,
        "features_mapped" => 2,
        "accepted" => [ accepted ],
        "review_errors" => [ error ],
        "zero_reason" => nil,
        "feature_results" => [
          { "feature_id" => "checkout", "complete" => true,
            "thesis_ids" => [ "checkout-thesis" ], "errors" => [] },
          { "feature_id" => "search", "complete" => false,
            "thesis_ids" => [], "errors" => [ error ] }
        ]
      )

      checkpoint = store.checkpoint_discovery!(token, envelope: partial, now: T0 + 1, backoff_sec: 60)

      refute checkpoint.fetch("complete")
      assert_equal "blocked", checkpoint.fetch("state")
      assert_equal [ "checkout-thesis" ], checkpoint.dig("dispositions", "accepted").map { |item| item.fetch("id") }
      assert_equal [ "checkout" ], checkpoint.fetch("feature_results").select { |item| item.fetch("complete") }
                                              .map { |item| item.fetch("feature_id") }
      assert_equal [ error ], checkpoint.fetch("review_errors")
      assert_empty store.claimable_jobs(now: T0 + 60)

      retry_token = store.claim_discovery!(
        "pr-7-stable", owner: "daemon-b", analysis_sha: "c" * 40,
        now: T0 + 61, lease_sec: 60
      )
      completed = store.checkpoint_discovery!(
        retry_token,
        envelope: partial.merge(
          "complete" => true,
          "review_errors" => [],
          "zero_reason" => nil,
          "feature_results" => [
            { "feature_id" => "checkout", "complete" => true,
              "thesis_ids" => [ "checkout-thesis" ], "errors" => [] },
            { "feature_id" => "search", "complete" => true,
              "thesis_ids" => [], "errors" => [] }
          ]
        ),
        now: T0 + 62
      )

      assert completed.fetch("complete")
      assert_equal [ "checkout-thesis" ], completed.dig("dispositions", "accepted").map { |item| item.fetch("id") }
      assert completed.fetch("feature_results").all? { |item| item.fetch("complete") }
    end
  end

  def test_feature_checkpoint_is_durable_without_releasing_the_discovery_claim
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      token = store.claim_discovery!(
        "pr-7-stable", owner: "daemon-a", analysis_sha: "c" * 40,
        now: T0, lease_sec: 60
      )
      accepted = disposition("checkout-thesis", "fp-checkout").merge(
        "thesis" => thesis_snapshot("checkout-thesis", "fp-checkout")
      )
      progress = complete_zero_envelope(dir).merge(
        "complete" => false,
        "features_mapped" => 1,
        "accepted" => [ accepted ],
        "zero_reason" => nil,
        "feature_results" => [
          { "feature_id" => "checkout", "complete" => true,
            "thesis_ids" => [ "checkout-thesis" ], "errors" => [] }
        ]
      )

      checkpoint = store.checkpoint_discovery_progress!(
        token, envelope: progress, now: T0 + 50, lease_sec: 60
      )

      assert_equal "analyzing", checkpoint.fetch("state")
      refute checkpoint.fetch("complete")
      assert_equal [ "checkout" ], checkpoint.fetch("feature_results").map { |item| item.fetch("feature_id") }
      assert_equal [ "checkout-thesis" ], checkpoint.dig("dispositions", "accepted").map { |item| item.fetch("id") }
      attempt = checkpoint.fetch("attempts").last
      assert_equal "claimed", attempt.fetch("state")
      assert_equal (T0 + 110).iso8601, attempt.fetch("expires_at")

      released = store.release_discovery!(token, reason: "process_died", now: T0 + 51, backoff_sec: 0)
      retry_token = store.claim_discovery!(
        "pr-7-stable", owner: "daemon-b", analysis_sha: "c" * 40,
        now: T0 + 52, lease_sec: 60
      )
      refute_nil retry_token
      assert_equal [ "checkout" ], released.fetch("feature_results").map { |item| item.fetch("feature_id") }
      assert_equal [ "checkout" ], store.read_job("pr-7-stable").fetch("feature_results")
                                          .map { |item| item.fetch("feature_id") }
    end
  end

  def test_initializes_deterministic_actions_without_reclassifying_theses
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      accepted = disposition("accepted", "fp-accepted").merge("thesis" => thesis_snapshot("accepted", "fp-accepted"))
      flagged = disposition("flagged", "fp-flagged").merge(
        "reasons" => [ "exceeds_file_cap" ],
        "thesis" => thesis_snapshot("flagged", "fp-flagged")
      )
      classified = classified_job(
        "policy" => { "discovery" => true, "auto_fix" => true, "issue_filing" => true },
        "dispositions" => { "accepted" => [ accepted ], "flagged" => [ flagged ], "suppressed" => [] }
      )
      store.write_job!(classified)

      initialized = store.initialize_actions!(
        "job-1",
        specifications: [
          { "thesis_id" => "flagged", "kind" => "issue", "family_id" => "af1-#{'f' * 64}" },
          { "thesis_id" => "accepted", "kind" => "fix" }
        ],
        now: T0
      )

      assert_equal classified.fetch("dispositions"), initialized.fetch("dispositions")
      assert_equal %w[fix issue], initialized.fetch("actions").map { |item| item.fetch("kind") }.sort
      assert initialized.fetch("actions").all? { |item| item.fetch("canonical_action_id").match?(Hive::RefactorPatrol::JobStore::ID_PATTERN) }
      assert initialized.fetch("actions").all? { |item| item.fetch("owner_job_id") == "job-1" }
      assert_equal "acting", initialized.fetch("state")
      assert_equal initialized, store.initialize_actions!(
        "job-1",
        specifications: [
          { "thesis_id" => "accepted", "kind" => "fix" },
          { "thesis_id" => "flagged", "kind" => "issue", "family_id" => "af1-#{'f' * 64}" }
        ],
        now: T0 + 1
      )
    end
  end

  def test_action_phase_block_backoff_does_not_send_classified_job_back_to_discovery
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.write_job!(classified_job)

      blocked = store.block_actions!(
        "job-1", reason: "family_ambiguous",
        evidence: { "thesis_id" => "accepted" },
        now: T0, backoff_sec: 60
      )

      assert_equal "classified", blocked.fetch("state")
      assert store.action_phase_backoff_active?(blocked, now: T0 + 59)
      assert_empty store.actionable_jobs(now: T0 + 59)
      assert_empty store.claimable_jobs(now: T0 + 59),
                   "an action-phase block must never become discovery work"
      assert_equal [ "job-1" ], store.actionable_jobs(now: T0 + 60).map { |job| job.fetch("job_id") }
      refute store.action_phase_backoff_active?(store.read_job("job-1"), now: T0 + 60)
    end
  end

  def test_disposition_thesis_snapshot_must_be_complete_and_match_identity
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      mismatched = disposition("accepted", "fp-accepted").merge(
        "thesis" => thesis_snapshot("other", "fp-accepted")
      )
      incomplete = disposition("accepted", "fp-accepted").merge(
        "thesis" => { "id" => "accepted", "feature_id" => "checkout", "fingerprint" => "fp-accepted" }
      )

      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.write_job!(classified_job(
          "dispositions" => { "accepted" => [ mismatched ], "flagged" => [], "suppressed" => [] }
        ))
      end
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        store.write_job!(classified_job(
          "dispositions" => { "accepted" => [ incomplete ], "flagged" => [], "suppressed" => [] }
        ))
      end
    end
  end

  def test_canonical_action_identity_is_repository_kind_and_family_or_fingerprint
    store = Hive::RefactorPatrol::JobStore.new("/tmp/example")
    fix = store.canonical_action_id(repository: "Acme/Demo", kind: "fix", identity: "fp/one")
    same = store.canonical_action_id(repository: "acme/demo", kind: "fix", identity: "fp/one")
    issue = store.canonical_action_id(repository: "acme/demo", kind: "issue", identity: "af1-#{'a' * 64}")
    other_repo = store.canonical_action_id(repository: "other/demo", kind: "fix", identity: "fp/one")
    other_host = store.canonical_action_id(
      repository: "acme/demo", host: "github.corp.example",
      kind: "fix", identity: "fp/one"
    )

    assert_equal fix, same
    refute_equal fix, issue
    refute_equal fix, other_repo
    refute_equal fix, other_host
    assert_match Hive::RefactorPatrol::JobStore::ID_PATTERN, fix
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      store.canonical_action_id(repository: "not-a-repository", kind: "fix", identity: "fp")
    end
  end

  def test_action_claims_are_serialized_fenced_and_monotonic
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      first = store.claim_action!("job-1", fix_action_id(store), owner: "runner-a", now: T0, lease_sec: 10)
      store.attach_action_process!(
        first, pid: 1234, process_start_time: "boot-1", pgid: 1234, now: T0 + 1
      )

      assert_nil store.claim_action!("job-1", fix_action_id(store), owner: "runner-b", now: T0 + 2)
      stale = first.merge(generation: first.fetch(:generation) + 1)
      assert_raises(Hive::RefactorPatrol::JobStore::StaleClaim) do
        store.record_action_receipt!(stale, key: "patch", value: { "commit_sha" => "d" * 40 }, now: T0 + 2)
      end

      assert_nil store.claim_action!(
        "job-1", fix_action_id(store), owner: "runner-b", now: T0 + 11,
        claim_resolver: ->(_claim) { :unresolved }
      )
      second = store.claim_action!(
        "job-1", fix_action_id(store), owner: "runner-b", now: T0 + 11,
        claim_resolver: ->(_claim) { :resolved }
      )
      assert_equal first.fetch(:generation) + 1, second.fetch(:generation)
      assert_raises(Hive::RefactorPatrol::JobStore::StaleClaim) do
        store.record_action_receipt!(first, key: "patch", value: { "commit_sha" => "d" * 40 }, now: T0 + 12)
      end
    end
  end

  def test_action_heartbeat_renews_only_the_live_exact_generation
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      action_id = fix_action_id(store)
      token = store.claim_action!(
        "job-1", action_id, owner: "runner-a", now: T0, lease_sec: 60,
        owner_pid: 4321, owner_process_start_time: "boot-action"
      )
      claims = store.active_claim_tokens_for_process(
        "job-1", pid: 4321, process_start_time: "boot-action"
      )
      assert_equal [ token.merge(kind: :action) ], claims

      renewed = store.renew_action_claim!(
        token, now: T0 + 50, lease_sec: 60,
        claim_resolver: ->(_claim) { :unresolved }
      )
      claim = renewed.dig("actions", 0, "claims", 0)
      assert_equal (T0 + 110).iso8601, claim.fetch("expires_at")

      assert_raises(Hive::RefactorPatrol::JobStore::StaleClaim) do
        store.renew_action_claim!(
          token, now: T0 + 111, lease_sec: 60,
          claim_resolver: ->(_claim) { :unresolved }
        )
      end
      replacement = store.claim_action!(
        "job-1", action_id, owner: "runner-b", now: T0 + 111,
        lease_sec: 60, claim_resolver: ->(_claim) { :resolved },
        owner_pid: 5678, owner_process_start_time: "boot-new"
      )
      refute_nil replacement
      assert_raises(Hive::RefactorPatrol::JobStore::StaleClaim) do
        store.renew_action_claim!(
          token, now: T0 + 112, lease_sec: 60,
          claim_resolver: ->(_claim) { :unresolved }
        )
      end
    end
  end

  def test_creation_intent_and_receipts_survive_crash_retry_idempotently
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      token = store.claim_action!("job-1", fix_action_id(store), owner: "runner-a", now: T0, lease_sec: 10)
      intent = { "operation" => "create_pr", "branch" => "hive/refactor/fp-accepted" }

      first = store.record_creation_intent!(token, intent: intent, now: T0 + 1)
      repeated = store.record_creation_intent!(token, intent: intent, now: T0 + 2)
      assert_equal first, repeated
      assert_equal intent, repeated.dig("actions", 0, "receipts", "creation_intent", "payload")

      recovered = store.claim_action!(
        "job-1", fix_action_id(store), owner: "runner-b", now: T0 + 11,
        claim_resolver: ->(_claim) { :resolved }
      )
      repaired = store.record_action_receipt!(
        recovered, key: "pr", value: { "url" => "https://github.com/acme/demo/pull/9" }, now: T0 + 12
      )
      assert_equal "https://github.com/acme/demo/pull/9", repaired.dig("actions", 0, "receipts", "pr", "url")
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.record_creation_intent!(
          recovered,
          intent: intent.merge("branch" => "hive/refactor/different"),
          now: T0 + 13
        )
      end
      completed = store.finish_action!(
        recovered,
        outcome: "pr_opened",
        receipts: {
          "creation_intent" => true,
          "pr_url" => "https://github.com/acme/demo/pull/9"
        },
        now: T0 + 14
      )
      assert completed.fetch("complete")
      assert_kind_of Hash, completed.dig("actions", 0, "receipts", "creation_intent")
    end
  end

  def test_stale_full_aggregate_cannot_erase_an_atomic_receipt
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      stale = store.read_job("job-1")
      token = store.claim_action!("job-1", fix_action_id(store), owner: "runner", now: T0)
      store.record_patch_receipt!(token, receipt: { "commit_sha" => "d" * 40 }, now: T0 + 1)

      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.write_job!(stale.merge("updated_at" => (T0 + 2).iso8601))
      end
      assert_equal "d" * 40, store.read_job("job-1").dig("actions", 0, "receipts", "patch", "commit_sha")
    end
  end

  def test_initialized_action_catalog_and_identity_are_immutable
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      original = store.read_job("job-1")
      action = original.fetch("actions").first
      variants = [
        original.merge("actions" => []),
        original.merge("actions" => original.fetch("actions") + [
          action.merge("canonical_action_id" => "fix-another")
        ]),
        original.merge("actions" => [ action.merge("owner_job_id" => "other-job") ]),
        original.merge("actions" => [ action.merge("thesis_id" => "other-thesis") ]),
        original.merge("actions" => [ action.merge("kind" => "issue") ]),
        original.merge("actions" => [ action.merge("family_id" => "af1-#{'a' * 64}") ]),
        original.merge("actions" => [ action.merge("created_at" => (T0 - 1).iso8601) ])
      ]

      variants.each do |replacement|
        assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
          store.write_job!(replacement.merge("updated_at" => (T0 + 1).iso8601))
        end
      end
      assert_equal original, store.read_job("job-1")
    end
  end

  def test_patch_fix_and_terminal_receipts_complete_parent_only_after_all_actions
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      accepted = disposition("accepted", "fp-accepted")
      flagged = disposition("flagged", "fp-flagged").merge("reasons" => [ "exceeds_file_cap" ])
      store.write_job!(classified_job(
        "policy" => { "discovery" => true, "auto_fix" => true, "issue_filing" => true },
        "dispositions" => { "accepted" => [ accepted ], "flagged" => [ flagged ], "suppressed" => [] }
      ))
      initialized = store.initialize_actions!(
        "job-1",
        specifications: [
          { "thesis_id" => "accepted", "kind" => "fix" },
          { "thesis_id" => "flagged", "kind" => "issue", "family_id" => "af1-#{'f' * 64}" }
        ],
        now: T0
      )
      fix_id = initialized.fetch("actions").find { |item| item.fetch("kind") == "fix" }.fetch("canonical_action_id")
      issue_id = initialized.fetch("actions").find { |item| item.fetch("kind") == "issue" }.fetch("canonical_action_id")

      fix_token = store.claim_action!("job-1", fix_id, owner: "fixer", now: T0 + 1)
      assert_nil store.claim_action!("job-1", issue_id, owner: "filer", now: T0 + 1)
      store.record_patch_receipt!(fix_token, receipt: { "commit_sha" => "d" * 40 }, now: T0 + 2)
      store.record_fix_receipt!(fix_token, receipt: { "validation" => "passed" }, now: T0 + 3)
      after_fix = store.finish_action!(
        fix_token, outcome: "pr_opened",
        receipts: { "pr_url" => "https://github.com/acme/demo/pull/9" }, now: T0 + 4
      )
      refute after_fix.fetch("complete")
      assert_equal "acting", after_fix.fetch("state")

      issue_token = store.claim_action!("job-1", issue_id, owner: "filer", now: T0 + 5)
      completed = store.finish_action!(
        issue_token, outcome: "issue_opened",
        receipts: { "issue_url" => "https://github.com/acme/demo/issues/10" }, now: T0 + 6
      )
      assert completed.fetch("complete")
      assert_equal "complete", completed.fetch("state")
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.write_job!(completed.merge("updated_at" => (T0 + 7).iso8601))
      end
    end
  end

  def test_nonterminal_release_blocks_parent_and_honors_backoff
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      token = store.claim_action!("job-1", fix_action_id(store), owner: "runner", now: T0)

      blocked = store.release_action!(
        token, outcome: "network_failure", receipts: { "error" => "timeout" },
        now: T0 + 1, backoff_sec: 60
      )
      assert_equal "blocked", blocked.fetch("state")
      assert_nil store.claim_action!("job-1", fix_action_id(store), owner: "runner", now: T0 + 60)
      reclaimed = store.claim_action!("job-1", fix_action_id(store), owner: "runner", now: T0 + 61)
      assert_equal token.fetch(:generation) + 1, reclaimed.fetch(:generation)
    end
  end

  def test_revalidated_patch_generations_are_append_only
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      token = store.claim_action!("job-1", fix_action_id(store), owner: "runner", now: T0)

      store.record_patch_receipt!(token, receipt: { "commit_sha" => "a" * 40 }, now: T0 + 1)
      store.record_patch_receipt!(token, receipt: { "commit_sha" => "b" * 40 }, now: T0 + 2)
      store.record_patch_receipt!(token, receipt: { "commit_sha" => "b" * 40 }, now: T0 + 3)

      receipts = store.read_job("job-1").fetch("actions").first.fetch("receipts")
      assert_equal "a" * 40, receipts.dig("patch", "commit_sha")
      assert_equal "b" * 40, receipts.dig("patch_2", "commit_sha")
      refute receipts.key?("patch_3"), "idempotent receipt retry must not add a generation"
    end
  end

  def test_revocation_blocks_unpublished_work_but_allows_remote_reconciliation
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      action_id = fix_action_id(store)

      assert_nil store.claim_action!("job-1", action_id, owner: "runner", authority: false, now: T0)
      assert_equal "authority_revoked", store.read_job("job-1").dig("actions", 0, "outcome")

      token = store.claim_action!("job-1", action_id, owner: "runner", authority: true, now: T0 + 1)
      store.record_creation_intent!(
        token,
        intent: { "operation" => "create_pr", "branch" => "hive/refactor/fp-accepted" },
        now: T0 + 2
      )
      store.release_action!(token, outcome: "remote_outcome_unknown", now: T0 + 3, backoff_sec: 0)

      continuation = store.claim_action!(
        "job-1", action_id, owner: "reconciler", authority: false, now: T0 + 4
      )
      assert continuation.fetch(:continuation_only)
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.record_creation_intent!(
          continuation,
          intent: { "operation" => "create_pr", "branch" => "hive/refactor/new" },
          now: T0 + 5
        )
      end
    end
  end

  def test_concurrent_claims_yield_one_action_owner
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      action_id = fix_action_id(store)
      ready = Queue.new
      start = Queue.new
      threads = %w[a b].map do |owner|
        Thread.new do
          ready << true
          start.pop
          store.claim_action!("job-1", action_id, owner: owner, now: T0)
        end
      end
      2.times { ready.pop }
      2.times { start << true }

      claims = threads.map(&:value).compact
      assert_equal 1, claims.size
      assert_includes %w[a b], claims.first.fetch(:owner)
    end
  end

  def test_concurrent_receipt_updates_are_merged_under_the_job_lock
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      token = store.claim_action!("job-1", fix_action_id(store), owner: "runner", now: T0)
      ready = Queue.new
      start = Queue.new
      updates = {
        "patch" => { "commit_sha" => "d" * 40 },
        "validation" => { "status" => "passed" }
      }
      threads = updates.map do |key, value|
        Thread.new do
          ready << true
          start.pop
          store.record_action_receipt!(token, key: key, value: value, now: T0 + 1)
        end
      end
      2.times { ready.pop }
      2.times { start << true }
      threads.each(&:value)

      receipts = store.read_job("job-1").dig("actions", 0, "receipts")
      assert_equal updates, receipts
    end
  end

  def test_actionable_jobs_are_separate_from_discovery_claims_and_respect_leases
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      action_id = fix_action_id(store)

      assert_equal [ "job-1" ], store.actionable_jobs(now: T0).map { |item| item.fetch("job_id") }
      assert_empty store.claimable_jobs(now: T0)
      token = store.claim_action!("job-1", action_id, owner: "runner", now: T0, lease_sec: 10)
      assert_empty store.actionable_jobs(now: T0 + 1)

      assert_equal [ "job-1" ], store.actionable_jobs(now: T0 + 11).map { |item| item.fetch("job_id") }
      store.release_action!(token, outcome: "network_failure", now: T0 + 1, backoff_sec: 60)
      assert_empty store.actionable_jobs(now: T0 + 60)
      assert_equal [ "job-1" ], store.actionable_jobs(now: T0 + 61).map { |item| item.fetch("job_id") }
      assert_empty store.claimable_jobs(now: T0 + 61)
    end
  end

  def test_newly_classified_job_is_actionable_before_catalog_initialization
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.write_job!(classified_job)

      assert_equal [ "job-1" ], store.actionable_jobs(now: T0).map { |item| item.fetch("job_id") }
      assert_empty store.claimable_jobs(now: T0)
    end
  end

  def test_later_occurrence_links_to_canonical_owner_and_reconciles_terminal_proof
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      action_id = fix_action_id(store)
      second_disposition = disposition("accepted-2", "fp-accepted")
      store.write_job!(classified_job(
        "job_id" => "job-2",
        "source" => source("number" => 8, "merge_sha" => "d" * 40),
        "dispositions" => { "accepted" => [ second_disposition ], "flagged" => [], "suppressed" => [] },
        "created_at" => (T0 + 1).iso8601,
        "updated_at" => (T0 + 1).iso8601
      ))
      linked = store.initialize_actions!(
        "job-2", specifications: [ { "thesis_id" => "accepted-2", "kind" => "fix" } ], now: T0 + 2
      )

      assert_equal "job-1", linked.dig("actions", 0, "owner_job_id")
      assert_empty linked.dig("actions", 0, "receipts")
      refute_includes store.actionable_jobs(now: T0 + 3).map { |item| item.fetch("job_id") }, "job-2"

      token = store.claim_action!("job-1", action_id, owner: "runner", now: T0 + 3)
      store.finish_action!(token, outcome: "no_diff", now: T0 + 4)
      assert_includes store.actionable_jobs(now: T0 + 5).map { |item| item.fetch("job_id") }, "job-2"
      completed_link = store.reconcile_linked_action!("job-2", action_id, now: T0 + 5)
      assert completed_link.fetch("complete")
      assert_equal "no_diff", completed_link.dig("actions", 0, "outcome")
      assert_empty completed_link.dig("actions", 0, "receipts")
    end
  end

  def test_materializes_late_terminal_proof_after_a_finished_claim_and_is_idempotent
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      action_id = fix_action_id(store)
      token = store.claim_action!("job-1", action_id, owner: "runner", now: T0)
      store.release_action!(token, outcome: "network_failure", now: T0 + 1, backoff_sec: 0)
      proof = terminal_proof(action_id, project_root: File.join(dir, "foreign"))

      linked = store.materialize_terminal_proof!(
        "job-1", action_id, proof: proof, now: T0 + 2
      )
      repeated = store.materialize_terminal_proof!(
        "job-1", action_id, proof: proof, now: T0 + 3
      )

      assert linked.fetch("complete")
      assert_equal linked, repeated
      action = linked.fetch("actions").first
      assert action.fetch("terminal")
      assert_equal "pr_opened", action.fetch("outcome")
      assert_equal proof, action.dig("receipts", "canonical_action_link")
      assert_equal "released", action.dig("claims", 0, "state")
    end
  end

  def test_late_terminal_proof_rejects_active_claims_or_existing_receipts
    with_tmp_dir do |root|
      active_root = File.join(root, "active")
      active_store = initialized_store(active_root)
      active_id = fix_action_id(active_store)
      active_store.claim_action!("job-1", active_id, owner: "runner", now: T0)

      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        active_store.materialize_terminal_proof!(
          "job-1", active_id,
          proof: terminal_proof(active_id, project_root: File.join(root, "foreign")),
          now: T0 + 1
        )
      end

      receipt_root = File.join(root, "receipt")
      receipt_store = initialized_store(receipt_root)
      receipt_id = fix_action_id(receipt_store)
      token = receipt_store.claim_action!("job-1", receipt_id, owner: "runner", now: T0)
      receipt_store.record_action_receipt!(
        token, key: "validation", value: { "passed" => true }, now: T0 + 1
      )
      receipt_store.release_action!(
        token, outcome: "network_failure", now: T0 + 2, backoff_sec: 0
      )

      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        receipt_store.materialize_terminal_proof!(
          "job-1", receipt_id,
          proof: terminal_proof(receipt_id, project_root: File.join(root, "foreign")),
          now: T0 + 3
        )
      end


      linked_root = File.join(root, "linked")
      linked_store = initialized_store(linked_root)
      linked_store.write_job!(classified_job(
        "job_id" => "job-2",
        "source" => source("number" => 8, "merge_sha" => "d" * 40),
        "created_at" => (T0 + 1).iso8601,
        "updated_at" => (T0 + 1).iso8601
      ))
      linked = linked_store.initialize_actions!(
        "job-2", specifications: [ { "thesis_id" => "accepted", "kind" => "fix" } ],
        now: T0 + 2
      )
      linked_id = linked.dig("actions", 0, "canonical_action_id")
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        linked_store.materialize_terminal_proof!(
          "job-2", linked_id,
          proof: terminal_proof(linked_id, project_root: File.join(root, "foreign")),
          now: T0 + 3
        )
      end
    end
  end

  def test_terminal_local_action_cannot_silently_accept_a_foreign_proof
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      action_id = fix_action_id(store)
      token = store.claim_action!("job-1", action_id, owner: "runner", now: T0)
      store.finish_action!(token, outcome: "no_diff", now: T0 + 1)

      error = assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.materialize_terminal_proof!(
          "job-1", action_id,
          proof: terminal_proof(action_id, project_root: File.join(dir, "foreign")),
          now: T0 + 2
        )
      end
      assert_match(/terminal canonical action proof conflicts/, error.message)
    end
  end

  def test_terminal_proof_requires_an_exact_owner_and_receipt_shape
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      action_id = fix_action_id(store)
      malformed_owner = terminal_proof(action_id, project_root: File.join(dir, "foreign"))
      malformed_owner["owner"].delete("merge_sha")
      malformed_receipts = terminal_proof(action_id, project_root: File.join(dir, "foreign"))
      malformed_receipts["proof"]["untrusted"] = true
      invalid_digest = terminal_proof(action_id, project_root: File.join(dir, "foreign"))
      invalid_digest["proof_digest"] = "0" * 64

      [ redigest_terminal_proof(malformed_owner),
        redigest_terminal_proof(malformed_receipts),
        invalid_digest ].each do |proof|
        assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
          store.materialize_terminal_proof!(
            "job-1", action_id, proof: proof, now: T0 + 1
          )
        end
      end
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        store.materialize_terminal_proof!("job-1", action_id, proof: {}, now: T0 + 1)
      end
    end
  end

  def test_action_initialization_rejects_terminal_proofs_for_unknown_actions
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.write_job!(classified_job)
      specification = { "thesis_id" => "accepted", "kind" => "fix" }
      unknown_id = "fix-#{'f' * 64}"

      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.initialize_actions!(
          "job-1",
          specifications: [ specification ],
          terminal_proofs: {
            unknown_id => terminal_proof(unknown_id, project_root: File.join(dir, "foreign"))
          },
          now: T0
        )
      end
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        store.initialize_actions!(
          "job-1",
          specifications: [ specification ],
          terminal_proofs: [],
          now: T0
        )
      end

      action_id = store.plan_actions(
        "job-1", specifications: [ specification ]
      ).first.fetch("canonical_action_id")
      linked = store.initialize_actions!(
        "job-1",
        specifications: [ specification ],
        terminal_proofs: {
          action_id => terminal_proof(action_id, project_root: File.join(dir, "foreign"))
        },
        now: T0
      )
      assert linked.fetch("complete")
      assert_equal "pr_opened", linked.dig("actions", 0, "outcome")
    end
  end

  def test_manifest_and_scheduler_errors_are_typed_and_expired_claims_are_visible
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        store.enqueue_manifest!(manifest.except("job_id"), policy: intake_policy, now: T0)
      end

      store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      token = store.claim_discovery!(
        "pr-7-stable", owner: "daemon", analysis_sha: "c" * 40,
        now: T0, lease_sec: 10
      )
      assert_equal [ "pr-7-stable" ],
                   store.claimable_jobs(now: T0 + 11).map { |item| item.fetch("job_id") }

      invalid = store.read_job("pr-7-stable")
      invalid["attempts"].last["expires_at"] = "not-a-time"
      store.define_singleton_method(:jobs) { [ invalid ] }
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.claimable_jobs(now: T0 + 11)
      end

      queued = job(
        "state" => "queued", "complete" => false, "actions" => [],
        "attempts" => [ { "next_eligible_at" => "not-a-time" } ]
      )
      store.define_singleton_method(:jobs) { [ queued ] }
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.eligible_jobs(now: T0)
      end

      active = initialized_store(File.join(dir, "actions"))
      active_token = active.claim_action!("job-1", fix_action_id(active), owner: "runner", now: T0)
      malformed_action = active.read_job("job-1")
      malformed_action.dig("actions", 0, "claims", 0)["expires_at"] = "not-a-time"
      active.define_singleton_method(:jobs) { [ malformed_action ] }
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        active.actionable_jobs(now: T0 + 1)
      end
      refute_nil active_token

      invalid_backoff = job("attempts" => [ { "kind" => "action_block", "next_eligible_at" => "never" } ])
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.action_phase_backoff_active?(invalid_backoff, now: T0)
      end
      refute_nil token
    end
  end

  def test_discovery_claim_guards_resolver_checkout_and_child_identity
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      first = store.claim_discovery!(
        "pr-7-stable", owner: "one", analysis_sha: "c" * 40,
        now: T0, lease_sec: 10
      )
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.attach_discovery_process!(first, pid: 1, process_start_time: "", pgid: 1, now: T0 + 1)
      end
      assert_nil store.claim_discovery!(
        "pr-7-stable", owner: "two", analysis_sha: "c" * 40,
        now: T0 + 11, claim_resolver: ->(*) { raise IOError, "resolver failed" }
      )
      reclaimed = store.claim_discovery!(
        "pr-7-stable", owner: "two", analysis_sha: "c" * 40,
        now: T0 + 11, claim_resolver: ->(*) { :resolved }
      )
      store.release_discovery!(reclaimed, reason: "retry", now: T0 + 12, backoff_sec: 0)
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.claim_discovery!(
          "pr-7-stable", owner: "three", analysis_sha: "d" * 40, now: T0 + 13
        )
      end
    end
  end

  def test_block_discovery_records_retry_evidence_and_is_idempotent_for_complete_jobs
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      blocked = store.block_discovery!(
        "pr-7-stable", reason: "checkout_failed", evidence: { "ref" => "main" },
        now: T0, backoff_sec: 30
      )
      assert_equal "blocked", blocked.fetch("state")
      assert_equal "checkout_failed", blocked.fetch("attempts").last.fetch("reason")
      assert_equal (T0 + 30).iso8601, blocked.fetch("attempts").last.fetch("next_eligible_at")

      completed = Hive::RefactorPatrol::JobStore.new(File.join(dir, "complete"))
      completed.write_job!(job)
      assert_equal job, completed.block_discovery!("job-1", reason: "ignored", now: T0)
    end
  end

  def test_action_planning_and_claim_input_guards_fail_closed
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.write_job!(classified_job)

      [ nil, [ "not-an-object" ] ].each do |invalid|
        assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
          store.plan_actions("job-1", specifications: invalid)
        end
        assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
          store.initialize_actions!("job-1", specifications: invalid, now: T0)
        end
      end
      [ "", "github.com/path", "[" ].each do |host|
        assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
          store.canonical_action_id(repository: "acme/demo", host: host, kind: "fix", identity: "fp")
        end
      end
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.canonical_action_id(repository: "acme/demo", kind: "delete", identity: "fp")
      end

      initialized = store.initialize_actions!(
        "job-1", specifications: [ { "thesis_id" => "accepted", "kind" => "fix" } ], now: T0
      )
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.initialize_actions!("job-1", specifications: [], now: T0 + 1)
      end
      action_id = initialized.dig("actions", 0, "canonical_action_id")
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.claim_action!("job-1", action_id, owner: "runner", lease_sec: 0, now: T0)
      end
      token = store.claim_action!("job-1", action_id, owner: "runner", now: T0, lease_sec: 10)
      assert_nil store.claim_action!(
        "job-1", action_id, owner: "other", now: T0 + 11,
        claim_resolver: ->(*) { raise IOError, "resolver failed" }
      )
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.claim_action!("job-1", action_id, owner: "other", now: "invalid")
      end
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.attach_action_process!(token, pid: 1, process_start_time: "", pgid: 1, now: T0 + 1)
      end
    end
  end

  def test_complete_jobs_accept_only_an_empty_idempotent_action_plan
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      complete_without_actions = job("actions" => [])
      store.write_job!(complete_without_actions)

      assert_equal complete_without_actions,
                   store.initialize_actions!("job-1", specifications: [], now: T0)
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.initialize_actions!(
          "job-1", specifications: [ { "thesis_id" => "accepted", "kind" => "fix" } ], now: T0
        )
      end
    end
  end

  def test_linked_actions_cannot_be_claimed_and_owner_actions_cannot_be_reconciled
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      action_id = fix_action_id(store)
      store.write_job!(classified_job(
        "job_id" => "job-2",
        "source" => source("number" => 8, "merge_sha" => "d" * 40),
        "created_at" => (T0 + 1).iso8601, "updated_at" => (T0 + 1).iso8601
      ))
      linked = store.initialize_actions!(
        "job-2", specifications: [ { "thesis_id" => "accepted", "kind" => "fix" } ], now: T0 + 2
      )
      assert_equal action_id, linked.dig("actions", 0, "canonical_action_id")
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.claim_action!("job-2", action_id, owner: "runner", now: T0 + 3)
      end
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.reconcile_linked_action!("job-1", action_id, now: T0 + 3)
      end
    end
  end

  def test_receipt_and_outcome_input_guards_are_strict
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      token = store.claim_action!("job-1", fix_action_id(store), owner: "runner", now: T0)

      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        store.record_creation_intent!(token, intent: {}, now: T0 + 1)
      end
      [ "", "creation_intent" ].each do |key|
        assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
          store.record_action_receipt!(token, key: key, value: true, now: T0 + 1)
        end
      end
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        store.record_action_receipts!(token, receipts: [], now: T0 + 1)
      end
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.record_action_receipts!(token, receipts: { "creation_intent" => true }, now: T0 + 1)
      end
      [
        { terminal: nil, blocked: false, backoff_sec: 0 },
        { terminal: false, blocked: "yes", backoff_sec: 0 },
        { terminal: false, blocked: true, backoff_sec: -1 }
      ].each do |options|
        assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
          store.record_action_outcome!(token, outcome: "failed", now: T0 + 1, **options)
        end
      end
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.finish_action!(
          token, outcome: "done", receipts: { "creation_intent" => true }, now: T0 + 1
        )
      end
      store.record_action_receipt!(token, key: "validation", value: true, now: T0 + 1)
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.record_action_receipt!(token, key: "validation", value: false, now: T0 + 2)
      end
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.assert_action_claim!({}, now: T0)
      end
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.release_discovery!({}, reason: "bad-token", now: T0)
      end
    end
  end

  def test_continuation_claim_reuses_only_its_existing_creation_intent
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      action_id = fix_action_id(store)
      intent = { "operation" => "create_pr", "branch" => "hive/refactor/fp-accepted" }
      token = store.claim_action!("job-1", action_id, owner: "runner", now: T0)
      store.record_creation_intent!(token, intent: intent, now: T0 + 1)
      store.release_action!(token, outcome: "remote_outcome_unknown", now: T0 + 2, backoff_sec: 0)
      continuation = store.claim_action!(
        "job-1", action_id, owner: "reconciler", authority: false, now: T0 + 3
      )

      unchanged = store.record_creation_intent!(continuation, intent: intent, now: T0 + 4)

      assert_equal intent, unchanged.dig("actions", 0, "receipts", "creation_intent", "payload")
    end
  end

  def test_action_authority_and_repository_inputs_cannot_broaden_the_snapshot
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.write_job!(classified_job)

      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.plan_actions("job-1", specifications: [ { "thesis_id" => "accepted", "kind" => "other" } ])
      end
      denied_fix = Hive::RefactorPatrol::JobStore.new(File.join(dir, "denied-fix"))
      denied_fix.write_job!(classified_job(
        "policy" => { "discovery" => true, "auto_fix" => false, "issue_filing" => false }
      ))
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        denied_fix.plan_actions(
          "job-1", specifications: [ { "thesis_id" => "accepted", "kind" => "fix" } ]
        )
      end

      issue_root = File.join(dir, "issues")
      issue_store = Hive::RefactorPatrol::JobStore.new(issue_root)
      issue_store.write_job!(classified_job(
        "policy" => { "discovery" => true, "auto_fix" => false, "issue_filing" => false }
      ))
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        issue_store.plan_actions(
          "job-1", specifications: [ { "thesis_id" => "accepted", "kind" => "issue", "family_id" => "af1" } ]
        )
      end

      enabled_issue = Hive::RefactorPatrol::JobStore.new(File.join(dir, "enabled-issue"))
      enabled_issue.write_job!(classified_job(
        "policy" => { "discovery" => true, "auto_fix" => false, "issue_filing" => true }
      ))
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        enabled_issue.plan_actions(
          "job-1", specifications: [ { "thesis_id" => "accepted", "kind" => "issue" } ]
        )
      end

      queued = Hive::RefactorPatrol::JobStore.new(File.join(dir, "queued"))
      queued.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        queued.plan_actions("pr-7-stable", specifications: [])
      end

      invalid_url = classified_job("source" => source("url" => "["))
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        enabled_issue.send(
          :normalize_action_specifications,
          invalid_url,
          [ { "thesis_id" => "accepted", "kind" => "fix" } ],
          "/tmp/job.json"
        )
      end
    end
  end

  def test_claim_renewal_and_idempotent_receipts_cover_liveness_boundaries
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      action_id = fix_action_id(store)
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.renew_action_claim!({}, now: T0, lease_sec: 0)
      end
      token = store.claim_action!("job-1", action_id, owner: "runner", now: T0)
      assert_raises(Hive::RefactorPatrol::JobStore::StaleClaim) do
        store.renew_action_claim!(
          token, now: T0 + 1, claim_resolver: ->(*) { raise IOError, "cannot inspect" }
        )
      end
      store.record_action_receipt!(token, key: "validation", value: true, now: T0 + 2)
      unchanged = store.record_action_receipt!(token, key: "validation", value: true, now: T0 + 3)
      assert_equal true, unchanged.dig("actions", 0, "receipts", "validation")
    end
  end

  def test_index_rebuild_rejects_duplicate_or_missing_canonical_owners
    with_tmp_dir do |root|
      duplicate_store = Hive::RefactorPatrol::JobStore.new(File.join(root, "duplicate"))
      duplicate_store.write_job!(job)
      duplicate_store.write_job!(job(
        "job_id" => "job-2",
        "source" => source("number" => 8, "merge_sha" => "d" * 40),
        "dispositions" => {
          "accepted" => [ disposition("accepted-2", "fp-accepted") ],
          "flagged" => [], "suppressed" => []
        },
        "actions" => [ action.merge("thesis_id" => "accepted-2", "owner_job_id" => "job-2") ]
      ))
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        duplicate_store.rebuild_indexes!
      end
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        duplicate_store.send(:canonical_owner_action, "fix-fp-accepted")
      end

      missing_store = Hive::RefactorPatrol::JobStore.new(File.join(root, "missing"))
      missing_store.write_job!(job(
        "job_id" => "job-2",
        "source" => source("number" => 8, "merge_sha" => "d" * 40),
        "dispositions" => {
          "accepted" => [ disposition("accepted-2", "fp-accepted") ],
          "flagged" => [], "suppressed" => []
        },
        "actions" => [
          action.merge(
            "thesis_id" => "accepted-2", "owner_job_id" => "missing-owner", "receipts" => {}
          )
        ]
      ))
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        missing_store.rebuild_indexes!
      end
    end
  end

  def test_discovery_payload_validation_rejects_each_inconsistent_progress_shape
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      store.claim_discovery!("pr-7-stable", owner: "runner", analysis_sha: "c" * 40, now: T0)
      aggregate = store.read_job("pr-7-stable")
      valid = complete_zero_envelope(dir)

      invalid_payloads = []
      invalid_payloads << valid.merge("job_id" => "other")
      invalid_payloads << valid.merge("review_errors" => "bad")
      invalid_payloads << valid.merge("features_mapped" => 2)
      invalid_payloads << valid.merge(
        "feature_results" => [ valid.fetch("feature_results").first.merge("complete" => "yes") ]
      )
      retry_error = { "feature_id" => "checkout", "error" => "timeout" }
      incomplete = valid.fetch("feature_results").first.merge(
        "complete" => false, "errors" => [ retry_error ]
      )
      invalid_payloads << valid.merge("review_errors" => [ retry_error ], "feature_results" => [ incomplete ])
      invalid_payloads << valid.merge("review_errors" => [ retry_error ])
      invalid_payloads << valid.merge(
        "complete" => false, "zero_reason" => nil, "review_errors" => [],
        "feature_results" => valid.fetch("feature_results")
      )
      invalid_payloads.each do |payload|
        assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
          store.send(:assert_matching_discovery_payload!, aggregate, payload)
        end
      end
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:assert_matching_discovery_payload!, aggregate, valid, intermediate: true)
      end
      missing = valid.dup
      missing.delete("zero_reason")
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:assert_matching_discovery_payload!, aggregate, missing)
      end
    end
  end

  def test_discovery_resume_rejects_changed_features_thesis_lists_and_snapshots
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      accepted = disposition("checkout-thesis", "fp-checkout").merge(
        "thesis" => thesis_snapshot("checkout-thesis", "fp-checkout")
      )
      prior_result = {
        "feature_id" => "checkout", "complete" => true,
        "thesis_ids" => [ "checkout-thesis" ], "errors" => []
      }
      aggregate = classified_job(
        "dispositions" => { "accepted" => [ accepted ], "flagged" => [], "suppressed" => [] },
        "feature_results" => [ prior_result ]
      )
      changed_feature = complete_zero_envelope(dir).merge(
        "accepted" => [ accepted ], "zero_reason" => nil,
        "feature_results" => [ prior_result.merge("thesis_ids" => []) ]
      )
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:merge_discovery_progress!, aggregate, changed_feature)
      end

      no_prior = aggregate.merge("feature_results" => [])
      mismatched_ids = changed_feature.merge(
        "feature_results" => [ prior_result.merge("thesis_ids" => [ "other" ]) ]
      )
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:merge_discovery_progress!, no_prior, mismatched_ids)
      end

      changed_thesis = JSON.parse(JSON.generate(changed_feature))
      changed_thesis["accepted"][0]["score"] = 0.1
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:merge_discovery_progress!, no_prior, changed_thesis)
      end
    end
  end

  def test_manifest_version_and_raw_job_version_errors_are_distinct
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        store.enqueue_manifest!(manifest("schema_version" => 1), policy: intake_policy, now: T0)
      end
      jobs_dir = File.join(store.root, "jobs")
      FileUtils.mkdir_p(jobs_dir)
      File.write(File.join(jobs_dir, "missing-version.json"), JSON.generate(job("schema_version" => "two")))
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) { store.read_job("missing-version") }

      payload = job(
        "job_id" => "payload-id",
        "actions" => [ action.merge("owner_job_id" => "payload-id") ]
      )
      File.write(File.join(jobs_dir, "filename-id.json"), JSON.generate(payload))
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) { store.read_job("filename-id") }
    end
  end

  def test_strict_job_validation_rejects_policy_state_and_completion_conflicts
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      invalid = [
        [ job("schema_version" => "two"), Hive::RefactorPatrol::JobStore::CorruptRecord ],
        [ job("schema_version" => 99), Hive::RefactorPatrol::JobStore::UnsupportedVersion ],
        [ job("complete" => false), Hive::RefactorPatrol::JobStore::InconsistentRecord ],
        [ job("zero_reason" => "unknown"), Hive::RefactorPatrol::JobStore::InconsistentRecord ],
        [ job("dispositions" => { "accepted" => [], "flagged" => [], "suppressed" => [] },
              "actions" => [], "zero_reason" => nil), Hive::RefactorPatrol::JobStore::InconsistentRecord ],
        [ job("actions" => [ action.merge("terminal" => false, "outcome" => "queued") ]),
          Hive::RefactorPatrol::JobStore::InconsistentRecord ]
      ]
      invalid.each do |aggregate, error|
        assert_raises(error) { store.send(:validate_job!, aggregate, path: "/tmp/job.json") }
      end

      missing = job
      unstable = Class.new(Hash) do
        def fetch(key, *args)
          if key == "analysis_sha"
            raise KeyError.new("missing later", receiver: self, key: key)
          end

          super
        end
      end.new.tap { |value| missing.each { |key, item| value[key] = item } }
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        store.send(:validate_job!, unstable, path: "/tmp/job.json")
      end
    end
  end

  def test_action_policy_snapshot_validation_is_strict
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      action_policy = {
        "default_branch" => "main", "auto_fix_agent" => "codex", "min_confidence" => "high",
        "commands" => { "docs" => nil, "format" => nil, "lint" => nil,
                        "typecheck" => nil, "test" => "bin/test", "public_contract" => nil },
        "caps" => { "single_feature_only" => true, "allow_dependency_bumps" => false,
                    "allow_public_api_changes" => false, "max_files" => 8,
                    "max_diff_lines" => 400, "allow_cross_feature" => false },
        "issue_min_leverage_score" => 0.5
      }
      valid = job("policy" => job.fetch("policy").merge(
        "action" => action_policy, "epoch" => "a" * 64, "captured_at" => T0.iso8601
      ))
      assert_equal valid, store.send(:validate_job!, valid, path: "/tmp/job.json")

      mutations = [
        ->(value) { value["policy"]["epoch"] = "bad" },
        ->(value) { value.dig("policy", "action")["min_confidence"] = "certain" },
        ->(value) { value.dig("policy", "action", "commands")["test"] = "" },
        ->(value) { value.dig("policy", "action", "caps")["max_files"] = 0 },
        ->(value) { value.dig("policy", "action")["issue_min_leverage_score"] = 2 }
      ]
      mutations.each do |mutate|
        candidate = JSON.parse(JSON.generate(valid))
        mutate.call(candidate)
        assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
          store.send(:validate_job!, candidate, path: "/tmp/job.json")
        end
      end
    end
  end

  def test_feature_completion_cannot_claim_success_while_retaining_errors
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      store.enqueue_manifest!(manifest, policy: intake_policy, now: T0)
      store.claim_discovery!("pr-7-stable", owner: "runner", analysis_sha: "c" * 40, now: T0)
      aggregate = store.read_job("pr-7-stable")
      retry_error = { "feature_id" => "checkout", "error" => "timeout" }
      result = complete_zero_envelope(dir).fetch("feature_results").first.merge(
        "complete" => true, "errors" => [ retry_error ]
      )
      payload = complete_zero_envelope(dir).merge(
        "review_errors" => [ retry_error ], "feature_results" => [ result ]
      )

      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:assert_matching_discovery_payload!, aggregate, payload)
      end
    end
  end

  def test_discovery_resume_rejects_a_changed_existing_thesis_snapshot
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      accepted = disposition("checkout-thesis", "fp-checkout").merge(
        "thesis" => thesis_snapshot("checkout-thesis", "fp-checkout")
      )
      aggregate = classified_job(
        "dispositions" => { "accepted" => [ accepted ], "flagged" => [], "suppressed" => [] },
        "feature_results" => []
      )
      changed = JSON.parse(JSON.generate(accepted))
      changed["score"] = 0.1
      payload = complete_zero_envelope(dir).merge(
        "accepted" => [ changed ], "zero_reason" => nil,
        "feature_results" => [
          { "feature_id" => "checkout", "complete" => true,
            "thesis_ids" => [ "checkout-thesis" ], "errors" => [] }
        ]
      )

      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:merge_discovery_progress!, aggregate, payload)
      end
    end
  end

  def test_job_validation_rejects_claim_and_materialized_proof_inconsistencies
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      action_id = fix_action_id(store)
      token = store.claim_action!("job-1", action_id, owner: "runner", now: T0)
      claimed = store.read_job("job-1")

      invalid_thesis = classified_job
      invalid_thesis.dig("dispositions", "accepted", 0)["thesis"] = []
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        store.send(:validate_job!, invalid_thesis, path: "/tmp/job.json")
      end

      proof_conflict = JSON.parse(JSON.generate(claimed))
      proof_conflict.dig("actions", 0)["claims"] = []
      proof = terminal_proof(action_id, project_root: File.join(dir, "foreign"))
      proof_conflict.dig("actions", 0)["receipts"] = proof.fetch("proof").merge(
        "canonical_action_link" => proof
      )
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:validate_job!, proof_conflict, path: "/tmp/job.json")
      end

      linked_claim = JSON.parse(JSON.generate(claimed))
      linked_claim.dig("actions", 0)["owner_job_id"] = "other-job"
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:validate_job!, linked_claim, path: "/tmp/job.json")
      end

      claim_mutations = [
        ->(claim) { claim["generation"] = 0 },
        ->(claim) { claim["state"] = "unknown" },
        ->(claim) { claim["authority"] = "admin" },
        ->(claim) { claim["owner_pid"] = 0 },
        ->(claim) { claim["owner_process_start_time"] = "" }
      ]
      claim_mutations.each do |mutate|
        candidate = JSON.parse(JSON.generate(claimed))
        mutate.call(candidate.dig("actions", 0, "claims", 0))
        assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
          store.send(:validate_job!, candidate, path: "/tmp/job.json")
        end
      end

      second_active = JSON.parse(JSON.generate(claimed))
      second_active.dig("dispositions", "accepted") << disposition("accepted-2", "fp-2")
      duplicate = JSON.parse(JSON.generate(second_active.dig("actions", 0)))
      duplicate["canonical_action_id"] = "fix-#{'a' * 64}"
      duplicate["thesis_id"] = "accepted-2"
      duplicate["thesis_fingerprint"] = "fp-2"
      second_active.fetch("actions") << duplicate
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:validate_job!, second_active, path: "/tmp/job.json")
      end
      refute_nil token
    end
  end

  def test_job_and_claim_transitions_are_append_only_and_monotonic
    with_tmp_dir do |dir|
      store = initialized_store(dir)
      action_id = fix_action_id(store)
      token = store.claim_action!("job-1", action_id, owner: "runner", now: T0)
      claimed = store.read_job("job-1")
      path = "/tmp/job.json"

      changed_source = JSON.parse(JSON.generate(claimed))
      changed_source["source"]["base_branch"] = "develop"
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:validate_transition!, claimed, changed_source, path, action_api: true)
      end
      changed_analysis = JSON.parse(JSON.generate(claimed))
      changed_analysis["analysis_sha"] = "d" * 40
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:validate_transition!, claimed, changed_analysis, path, action_api: true)
      end

      before_actions = classified_job
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:validate_transition!, before_actions, claimed, path)
      end

      terminal = job
      changed_terminal = JSON.parse(JSON.generate(terminal))
      changed_terminal.dig("actions", 0)["outcome"] = "merged"
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:validate_transition!, terminal, changed_terminal, path, action_api: true)
      end

      removed_claim = JSON.parse(JSON.generate(claimed))
      removed_claim.dig("actions", 0)["claims"] = []
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:validate_transition!, claimed, removed_claim, path, action_api: true)
      end

      released = store.release_action!(token, outcome: "retry", now: T0 + 1, backoff_sec: 0)
      changed_finished = JSON.parse(JSON.generate(released))
      changed_finished.dig("actions", 0, "claims", 0)["outcome"] = "different"
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:validate_transition!, released, changed_finished, path, action_api: true)
      end

      heartbeat_back = JSON.parse(JSON.generate(claimed))
      heartbeat_back.dig("actions", 0, "claims", 0)["expires_at"] = (T0 - 1).iso8601
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:validate_transition!, claimed, heartbeat_back, path, action_api: true)
      end

      running_store = initialized_store(File.join(dir, "running"))
      running_id = fix_action_id(running_store)
      running_token = running_store.claim_action!("job-1", running_id, owner: "runner", now: T0)
      running_store.attach_action_process!(
        running_token, pid: 123, process_start_time: "boot", pgid: 123, now: T0 + 1
      )
      running = running_store.read_job("job-1")
      state_back = JSON.parse(JSON.generate(running))
      state_back.dig("actions", 0, "claims", 0)["state"] = "claimed"
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:validate_transition!, running, state_back, path, action_api: true)
      end
      changed_pid = JSON.parse(JSON.generate(running))
      changed_pid.dig("actions", 0, "claims", 0)["pid"] = 456
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:validate_transition!, running, changed_pid, path, action_api: true)
      end
    end
  end

  def test_low_level_validation_and_index_recovery_are_fail_closed
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::JobStore.new(dir)
      assert_equal [ { "a" => 1 } ], store.send(:deep_sort, [ { "a" => 1 } ])
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        store.send(:string_array!, [ "", "value" ], "values", "/tmp/job.json")
      end
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        store.send(:timestamp!, "not-a-time", "timestamp", "/tmp/job.json")
      end
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        store.send(:json_copy, Float::NAN)
      end

      store.write_job!(job)
      store.rebuild_indexes!
      assert_equal "job-1", store.action_index.dig("actions", "fix-fp-accepted", "owner_job_id")
      File.write(store.action_index_path, "[]")
      assert_equal "job-1", store.action_index.dig("actions", "fix-fp-accepted", "owner_job_id")
      File.write(store.action_index_path, "{")
      assert_equal "job-1", store.action_index.dig("actions", "fix-fp-accepted", "owner_job_id")

      replacement = ->(*) { raise Errno::EINVAL, "directory fsync unsupported" }
      with_replaced_singleton_method(File, :open, replacement) do
        assert_nil store.send(:fsync_directory, dir)
      end
    end
  end

  private

  def classified_job(overrides = {})
    job(
      "state" => "classified",
      "complete" => false,
      "actions" => [],
      "attempts" => [ { "number" => 1, "outcome" => "classified" } ]
    ).merge(overrides)
  end

  def initialized_store(dir)
    store = Hive::RefactorPatrol::JobStore.new(dir)
    store.write_job!(classified_job)
    store.initialize_actions!(
      "job-1", specifications: [ { "thesis_id" => "accepted", "kind" => "fix" } ], now: T0
    )
    store
  end

  def fix_action_id(store)
    store.read_job("job-1").fetch("actions").find { |item| item.fetch("kind") == "fix" }
         .fetch("canonical_action_id")
  end

  def terminal_proof(action_id, project_root:, outcome: "pr_opened",
                     receipts: { "pr_url" => "https://github.com/acme/demo/pull/41",
                                 "review_task_path" => "/review/task" })
    redigest_terminal_proof(
      "canonical_action_id" => action_id,
      "owner" => {
        "registration" => "foreign",
        "project_root" => project_root,
        "job_id" => "job-foreign",
        "pr_number" => 7,
        "merge_sha" => "b" * 40
      },
      "outcome" => outcome,
      "proof" => receipts
    )
  end

  def redigest_terminal_proof(proof)
    payload = proof.reject { |key, _| key == "proof_digest" }
    proof.merge(
      "proof_digest" => ::Digest::SHA256.hexdigest(JSON.generate(deep_sort_json(payload)))
    )
  end

  def deep_sort_json(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [ key, deep_sort_json(value.fetch(key)) ] }
    when Array
      value.map { |item| deep_sort_json(item) }
    else value
    end
  end

  def thesis_snapshot(id, fingerprint)
    {
      "id" => id,
      "feature_id" => "checkout",
      "feature" => "Checkout",
      "fingerprint" => fingerprint,
      "problem" => "Scattered policy",
      "cost" => "Repeated edits",
      "evidence" => [],
      "proposed_refactor" => "Consolidate policy",
      "feature_boundary" => { "owned_files" => [ "lib/checkout.rb" ] },
      "feature_hotspot" => {},
      "expected_leverage" => { "score" => 0.8 },
      "confidence" => "high",
      "risk" => { "flags" => [], "advisories" => [] },
      "required_validation" => { "commands" => [ "bin/test" ] },
      "admissible" => true,
      "admissibility_reason" => "",
      "follow_up_approval_state" => "pending"
    }
  end

  def job(overrides = {})
    {
      "schema" => "hive-refactor-patrol-job",
      "schema_version" => 2,
      "job_id" => "job-1",
      "source" => source,
      "analysis_sha" => "c" * 40,
      "policy" => { "discovery" => true, "auto_fix" => true, "issue_filing" => false },
      "state" => "complete",
      "complete" => true,
      "dispositions" => {
        "accepted" => [ disposition("accepted", "fp-accepted") ],
        "flagged" => [],
        "suppressed" => []
      },
      "feature_results" => [
        { "feature_id" => "checkout", "complete" => true, "thesis_ids" => [ "accepted" ], "errors" => [] }
      ],
      "review_errors" => [],
      "zero_reason" => nil,
      "attempts" => [ { "number" => 1, "outcome" => "complete" } ],
      "actions" => [ action ],
      "created_at" => "2026-07-10T10:00:00Z",
      "updated_at" => "2026-07-10T10:01:00Z"
    }.merge(overrides)
  end

  def source(overrides = {})
    {
      "url" => "https://github.com/acme/demo/pull/7",
      "number" => 7,
      "repository" => "acme/demo",
      "registration" => "demo",
      "base_branch" => "main",
      "base_sha" => "a" * 40,
      "merge_sha" => "b" * 40
    }.merge(overrides)
  end

  def disposition(id, fingerprint)
    {
      "id" => id,
      "feature_id" => "checkout",
      "fingerprint" => fingerprint,
      "score" => 0.8,
      "admissible" => true,
      "reasons" => []
    }
  end

  def action
    {
      "canonical_action_id" => "fix-fp-accepted",
      "thesis_id" => "accepted",
      "thesis_fingerprint" => "fp-accepted",
      "kind" => "fix",
      "owner_job_id" => "job-1",
      "outcome" => "pr_opened",
      "terminal" => true,
      "receipts" => { "pr_url" => "https://github.com/acme/demo/pull/9" }
    }
  end

  def manifest(overrides = {})
    {
      "schema" => "hive-refactor-patrol-pr-manifest",
      "schema_version" => 2,
      "job_id" => "pr-7-stable",
      "source" => source(
        "merged_at" => "2026-07-10T12:00:00Z"
      ),
      "files" => [ { "path" => "lib/checkout.rb", "status" => "modified" } ],
      "changed_paths" => [ "lib/checkout.rb" ],
      "manifest_checksum" => "a" * 64
    }.merge(overrides)
  end

  def intake_policy
    {
      "discovery" => true,
      "auto_fix" => false,
      "issue_filing" => false,
      "captured_at" => T0.iso8601
    }
  end

  def complete_zero_envelope(project_root)
    {
      "schema" => "hive-refactor-patrol",
      "schema_version" => 2,
      "ok" => true,
      "job_id" => "pr-7-stable",
      "project" => "demo",
      "project_root" => project_root,
      "dry_run" => false,
      "source_pr" => source(
        "merged_at" => "2026-07-10T12:00:00Z",
        "changed_paths" => [ "lib/checkout.rb" ],
        "manifest_checksum" => "a" * 64
      ),
      "analysis_sha" => "c" * 40,
      "complete" => true,
      "features_mapped" => 1,
      "accepted" => [],
      "flagged" => [],
      "suppressed" => [],
      "review_errors" => [],
      "feature_results" => [
        { "feature_id" => "checkout", "complete" => true, "thesis_ids" => [], "errors" => [] }
      ],
      "zero_reason" => "no_theses",
      "attempts" => [],
      "actions" => []
    }
  end
end
