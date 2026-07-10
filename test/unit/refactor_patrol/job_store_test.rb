require "test_helper"
require "hive/refactor_patrol/job_store"

class RefactorPatrolJobStoreTest < Minitest::Test
  include HiveTestHelper

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
end
