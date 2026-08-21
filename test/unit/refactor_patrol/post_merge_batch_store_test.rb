require "test_helper"
require "hive/refactor_patrol/post_merge_batch_store"

class RefactorPatrolPostMergeBatchStoreTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 8, 20, 12, 0, 0)

  def test_overlapping_recent_occurrences_freeze_one_batch_without_preliminary_jobs
    with_tmp_dir do |dir|
      store = build_store(dir)
      records = [
        classification("a", number: 10, paths: %w[lib/a.rb lib/shared.rb], merged_at: T0),
        classification("b", number: 11, paths: %w[lib/b.rb], merged_at: T0 + 300),
        classification("c", number: 12, paths: %w[lib/c.rb], merged_at: T0 + 301)
      ]
      mappings = {
        records[0].fetch("occurrence_id") => mapped(%w[lib/a.rb lib/shared.rb], "slice-shared"),
        records[1].fetch("occurrence_id") => mapped(%w[lib/b.rb], "slice-shared"),
        records[2].fetch("occurrence_id") => mapped(%w[lib/c.rb], "slice-other")
      }

      batch = store.claim!(
        primary_occurrence_id: records[0].fetch("occurrence_id"),
        classifications: records, analysis_sha: "f" * 40,
        mappings: mappings, now: T0 + 400
      )

      assert_equal "f" * 40, batch.fetch("analysis_sha")
      assert_equal records.first(2).map { |record| record.fetch("occurrence_id") },
                   batch.fetch("members").map { |member| member.fetch("occurrence_id") }
      assert_equal mappings.fetch(records[1].fetch("occurrence_id")),
                   batch.fetch("members").last.fetch("path_mappings")
      assert_equal batch, build_store(dir).fetch(batch.fetch("batch_id"))
      assert_equal [], Dir.glob(File.join(dir, "**", "jobs", "*.json"))
    end
  end

  def test_claimed_membership_never_accepts_late_occurrence_and_binding_waits_for_materialization
    with_tmp_dir do |dir|
      store = build_store(dir)
      first = classification("a", number: 10, paths: %w[lib/a.rb], merged_at: T0)
      first_map = { first.fetch("occurrence_id") => mapped(%w[lib/a.rb], "slice-shared") }
      batch = store.claim!(
        primary_occurrence_id: first.fetch("occurrence_id"), classifications: [ first ],
        analysis_sha: "f" * 40, mappings: first_map, now: T0
      )
      late = classification("b", number: 11, paths: %w[lib/b.rb], merged_at: T0 + 60)

      second = store.claim!(
        primary_occurrence_id: late.fetch("occurrence_id"), classifications: [ first, late ],
        analysis_sha: "e" * 40,
        mappings: first_map.merge(late.fetch("occurrence_id") => mapped(%w[lib/b.rb], "slice-shared")),
        now: T0 + 60
      )

      assert_equal [ first.fetch("occurrence_id") ], batch.fetch("members").map { |member| member.fetch("occurrence_id") }
      assert_equal [ late.fetch("occurrence_id") ], second.fetch("members").map { |member| member.fetch("occurrence_id") }
      assert_nil store.materialization_binding(first)
      marked = store.mark_materialized!(
        batch.fetch("batch_id"), job_id: batch.fetch("owner_job_id"),
        manifest_checksum: "a" * 64, now: T0 + 90
      )
      assert_equal "materialized", marked.fetch("status")
      assert_equal({
        "job_ids" => [ batch.fetch("owner_job_id") ],
        "manifest_checksums" => [ "a" * 64 ]
      }, store.materialization_binding(first))
      finalized = store.finalize!(
        batch.fetch("batch_id"), job_id: batch.fetch("owner_job_id"),
        manifest_checksum: "a" * 64
      )
      assert_equal "finalized", finalized.fetch("status")
      assert_equal [ second.fetch("batch_id") ], store.pending.map { |item| item.fetch("batch_id") }
      bound = first.merge(
        "materialization" => {
          "job_ids" => [ batch.fetch("owner_job_id") ],
          "manifest_checksums" => [ "a" * 64 ],
          "completed_at" => (T0 + 91).iso8601
        }
      )
      assert_equal({
        "job_ids" => [ batch.fetch("owner_job_id") ],
        "manifest_checksums" => [ "a" * 64 ]
      }, store.materialization_binding(bound), "binding replay accepts an already-bound classifier row")
    end
  end

  def test_fixed_chunks_split_oversized_occurrence_without_dropping_paths_across_restart
    with_tmp_dir do |dir|
      store = build_store(dir)
      paths = 513.times.map { |index| "lib/features/#{index}.rb" }
      record = classification("a", number: 10, paths: paths, merged_at: T0)
      mappings = { record.fetch("occurrence_id") => mapped(paths, "slice-shared") }

      first = store.claim!(
        primary_occurrence_id: record.fetch("occurrence_id"), classifications: [ record ],
        analysis_sha: "f" * 40, mappings: mappings, now: T0
      )
      assert store.unclaimed?(record)
      second = build_store(dir).claim!(
        primary_occurrence_id: record.fetch("occurrence_id"), classifications: [ record ],
        analysis_sha: "e" * 40, mappings: mappings, now: T0 + 1
      )

      refute store.unclaimed?(record)
      assert_equal [ 512, 1 ], [ first, second ].map { |batch| batch.dig("members", 0, "path_mappings").size }
      assert_equal paths,
                   [ first, second ].flat_map { |batch|
                     batch.dig("members", 0, "path_mappings").map { |mapping| mapping.fetch("path") }
                   }
      assert_nil store.materialization_binding(record)
    end
  end

  def test_read_rejects_batch_bytes_whose_content_derived_identity_changed
    with_tmp_dir do |dir|
      store = build_store(dir)
      record = classification("a", number: 10, paths: %w[lib/a.rb], merged_at: T0)
      batch = store.claim!(
        primary_occurrence_id: record.fetch("occurrence_id"), classifications: [ record ],
        analysis_sha: "f" * 40,
        mappings: { record.fetch("occurrence_id") => mapped(%w[lib/a.rb], "slice-a") },
        now: T0
      )
      path = File.join(dir, "batches", "records", "#{batch.fetch('batch_id')}.json")
      bytes = JSON.parse(File.binread(path))
      bytes["analysis_sha"] = "e" * 40
      File.binwrite(path, JSON.generate(bytes))

      error = assert_raises(Hive::RefactorPatrol::PostMergeBatchStore::Invalid) do
        build_store(dir).fetch(batch.fetch("batch_id"))
      end
      assert_match(/identity is invalid/, error.message)
    end
  end

  def test_claim_compacts_only_fully_consumed_batch_groups
    with_max_records(1) do
      with_tmp_dir do |dir|
        store = build_store(dir)
        first_record = classification("a", number: 10, paths: %w[lib/a.rb], merged_at: T0)
        first = claim(store, first_record, analysis_sha: "f" * 40)
        finalize(store, first)

        second_record = classification("b", number: 11, paths: %w[lib/b.rb], merged_at: T0 + 1)
        second = claim(store, second_record, analysis_sha: "e" * 40)

        assert_nil store.fetch(first.fetch("batch_id"))
        assert_equal second, store.fetch(second.fetch("batch_id"))
      end
    end
  end

  def test_finalized_partial_occurrence_is_retained_with_its_in_flight_chunk
    with_max_records(2) do
      with_tmp_dir do |dir|
        store = build_store(dir)
        paths = 513.times.map { |index| "lib/features/#{index}.rb" }
        split = classification("a", number: 10, paths: paths, merged_at: T0)
        first = claim(store, split, analysis_sha: "f" * 40)
        finalize(store, first)
        second = claim(store, split, analysis_sha: "e" * 40)
        newcomer = classification("b", number: 11, paths: %w[lib/new.rb], merged_at: T0 + 1)

        error = assert_raises(Hive::RefactorPatrol::PostMergeBatchStore::Invalid) do
          claim(store, newcomer, analysis_sha: "d" * 40)
        end

        assert_match(/in-flight work/, error.message)
        assert store.fetch(first.fetch("batch_id"))
        assert store.fetch(second.fetch("batch_id"))
      end
    end
  end

  private

  def build_store(dir)
    Hive::RefactorPatrol::PostMergeBatchStore.new(root: File.join(dir, "batches"))
  end

  def claim(store, record, analysis_sha:)
    store.claim!(
      primary_occurrence_id: record.fetch("occurrence_id"),
      classifications: [ record ], analysis_sha: analysis_sha,
      mappings: {
        record.fetch("occurrence_id") => mapped(
          record.dig("snapshot", "changed_paths"), "slice-shared"
        )
      },
      now: T0
    )
  end

  def finalize(store, batch)
    store.mark_materialized!(
      batch.fetch("batch_id"), job_id: batch.fetch("owner_job_id"),
      manifest_checksum: "a" * 64, now: T0
    )
    store.finalize!(
      batch.fetch("batch_id"), job_id: batch.fetch("owner_job_id"),
      manifest_checksum: "a" * 64
    )
  end

  def with_max_records(limit)
    original = Hive::RefactorPatrol::PostMergeBatchStore::MAX_RECORDS
    Hive::RefactorPatrol::PostMergeBatchStore.send(:remove_const, :MAX_RECORDS)
    Hive::RefactorPatrol::PostMergeBatchStore.const_set(:MAX_RECORDS, limit)
    yield
  ensure
    Hive::RefactorPatrol::PostMergeBatchStore.send(:remove_const, :MAX_RECORDS)
    Hive::RefactorPatrol::PostMergeBatchStore.const_set(:MAX_RECORDS, original)
  end

  def mapped(paths, slice_id)
    paths.map { |path| { "path" => path, "slice_ids" => [ slice_id ] } }
  end

  def classification(seed, number:, paths:, merged_at:)
    occurrence_id = Digest::SHA256.hexdigest(seed)
    {
      "occurrence_id" => occurrence_id, "status" => "feature", "decision" => "feature",
      "materialization" => nil, "registration" => "demo",
      "snapshot" => {
        "repository" => "acme/demo", "number" => number,
        "merge_sha" => number.to_s(16).rjust(40, "0"), "merged_at" => merged_at.iso8601,
        "changed_paths" => paths
      }
    }
  end
end
