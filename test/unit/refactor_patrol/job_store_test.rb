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

    assert_equal fix, same
    refute_equal fix, issue
    refute_equal fix, other_repo
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
      "zero_reason" => "no_theses",
      "attempts" => [],
      "actions" => []
    }
  end
end
