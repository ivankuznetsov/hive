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

      acting = partial.merge(
        "state" => "acting",
        "actions" => [ action.merge("terminal" => false, "outcome" => "validating", "receipts" => {}) ],
        "updated_at" => "2026-07-10T10:02:00Z"
      )
      store.write_job!(acting)
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

  private

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
