require "test_helper"
require "hive/daily_digest/store"

class DailyDigestStoreTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.iso8601("2026-08-30T12:00:00Z")

  def test_open_base_can_be_replaced_then_close_is_immutable
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      first = record("open", items: [])
      second = record("open", items: [ item("created") ])

      written = store.write_base(first)
      replaced = store.write_base(second)
      refute_equal written.fetch("record_id"), replaced.fetch("record_id")

      closed = store.write_base(record("closed", items: [ item("created") ]))
      closed_bytes = File.binread(store.base_path("2026-08-30"))
      assert_equal "closed", closed.fetch("lifecycle")

      assert_raises(Hive::DailyDigest::Store::ImmutableRecord) do
        store.write_base(record("closed", items: [ item("changed") ]))
      end
      assert_equal closed_bytes, File.binread(store.base_path("2026-08-30"))
      assert_equal 0o600, File.stat(store.base_path("2026-08-30")).mode & 0o777
    end
  end

  def test_amendments_are_append_only_idempotent_and_can_resolve_a_gap
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      store.write_base(record("closed", completeness: "partial", content: "unknown",
                             gaps: [ gap ]))
      amendment = {
        "amendment_id" => "recover:github:demo",
        "kind" => "gap_resolution",
        "source" => "github",
        "event_at" => nil,
        "observed_at" => "2026-08-31T08:00:00.000000Z",
        "amended_at" => "2026-08-31T08:00:01.000000Z",
        "items" => [],
        "resolved_gap_ids" => [ gap.fetch("gap_id") ]
      }

      first = store.append_amendment("2026-08-30", amendment)
      second = store.append_amendment("2026-08-30", amendment)
      assert_equal first, second
      assert_equal 1, store.read("2026-08-30").fetch("amendments").size
      assert_equal "complete", store.read("2026-08-30").fetch("effective_completeness")

      conflict = amendment.merge("source" => "task_journal")
      assert_raises(Hive::DailyDigest::Store::Conflict) do
        store.append_amendment("2026-08-30", conflict)
      end
    end
  end

  def test_later_amendment_can_resolve_a_gap_added_by_an_earlier_amendment
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      store.write_base(record("closed"))
      store.append_amendment(
        "2026-08-30",
        amendment(
          "gap", amended_at: "2026-08-31T08:00:01Z", gaps: [ gap ]
        )
      )
      assert_equal [ gap.fetch("gap_id") ],
                   store.read("2026-08-30").fetch("effective_gaps").map { |row| row.fetch("gap_id") }

      store.append_amendment(
        "2026-08-30",
        amendment(
          "recovery", amended_at: "2026-08-31T08:00:02Z",
          resolved_gap_ids: [ gap.fetch("gap_id") ]
        )
      )

      effective = store.read("2026-08-30")
      assert_empty effective.fetch("effective_gaps")
      assert_equal "complete", effective.fetch("effective_completeness")
      assert_equal "empty", effective.fetch("effective_content")
    end
  end

  def test_open_records_reject_amendments_and_pruning
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      store.write_base(record("open"))

      assert_raises(Hive::DailyDigest::Store::ImmutableRecord) do
        store.append_amendment("2026-08-30", amendment("late"))
      end
      assert_raises(Hive::DailyDigest::Store::ImmutableRecord) do
        store.prune("2026-08-30", pruned_at: NOW, reason: "operator_confirmed")
      end
    end
  end

  def test_frontier_overlay_is_written_only_when_it_changes
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      store.write_base(record("closed"))

      expected = { "project-1" => { "cursor" => 2 } }
      assert_equal expected, store.advance_frontiers("2026-08-30", expected)
      bytes = File.binread(store.frontier_path("2026-08-30"))
      assert_equal expected, store.advance_frontiers("2026-08-30", expected)
      assert_equal bytes, File.binread(store.frontier_path("2026-08-30"))
      assert_equal expected, store.read("2026-08-30").fetch("effective_source_frontiers")
    end
  end

  def test_effective_projection_deduplicates_late_attention
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      store.write_base(record("closed"))
      late = amendment("attention").merge(
        "attention" => [ { "attention_id" => "attention:one", "project_id" => "project-1" },
                           { "attention_id" => "attention:one", "project_id" => "project-1" } ]
      )

      store.append_amendment("2026-08-30", late)

      assert_equal [ "attention:one" ],
                   store.read("2026-08-30").fetch("attention").map { |row| row.fetch("attention_id") }
      assert_equal "non_empty", store.read("2026-08-30").fetch("effective_content")
    end
  end

  def test_conflicting_open_identity_is_rejected_defensively
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      path = store.base_path("2026-08-30")
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, "{}")
      existing = record("open").merge("local_date" => "2026-08-29")
      store.define_singleton_method(:read_json) { |_path| existing }

      assert_raises(Hive::DailyDigest::Store::Conflict) do
        store.write_base(record("open"))
      end
    end
  end

  def test_prune_removes_projection_but_keeps_owner_private_tombstone
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      store.write_base(record("closed"))
      receipt = store.prune("2026-08-30", pruned_at: NOW, reason: "operator_confirmed")

      refute File.exist?(store.base_path("2026-08-30"))
      assert_equal "pruned", store.read("2026-08-30").fetch("lifecycle")
      assert_equal receipt.fetch("receipt_id"), store.read("2026-08-30").fetch("receipt_id")
      assert_equal "a" * 64, receipt.dig("interval", "interval_id")
      assert_equal 86_400, receipt.dig("interval", "duration_seconds")
      assert_equal 0o600, File.stat(store.tombstone_path("2026-08-30")).mode & 0o777
    end
  end

  def test_prune_preserves_unresolved_gap_evidence_for_late_recovery_audit
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      store.write_base(record("closed", completeness: "partial", content: "unknown", gaps: [ gap ]))

      receipt = store.prune("2026-08-30", pruned_at: NOW, reason: "operator_confirmed")

      assert_equal [ "gap:github:demo" ],
                   receipt.fetch("effective_gaps").map { |entry| entry.fetch("gap_id") }
      assert_equal 86_400, store.intervals.first.fetch("duration_seconds")
    end
  end

  def test_prune_retry_finishes_projection_deletion_without_replacing_tombstone
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      store.write_base(record("closed"))
      store.append_amendment("2026-08-30", amendment("late"))

      original_remove = FileUtils.method(:remove_entry_secure)
      FileUtils.define_singleton_method(:remove_entry_secure) do |_path|
        raise Errno::EIO, "injected delete failure"
      end
      begin
        assert_raises(Errno::EIO) do
          store.prune("2026-08-30", pruned_at: NOW, reason: "operator_confirmed")
        end
      ensure
        FileUtils.define_singleton_method(:remove_entry_secure, original_remove)
      end
      assert_path_exists store.base_path("2026-08-30")
      tombstone_path = store.tombstone_path("2026-08-30")
      tombstone_bytes = File.binread(tombstone_path)
      tombstone_inode = File.stat(tombstone_path).ino

      store.prune(
        "2026-08-30", pruned_at: NOW + 60, reason: "retry must not replace receipt"
      )

      refute_path_exists File.dirname(store.base_path("2026-08-30"))
      assert_equal tombstone_bytes, File.binread(tombstone_path)
      assert_equal tombstone_inode, File.stat(tombstone_path).ino
    end
  end

  def test_pruned_discard_identity_ignores_retry_audit_time
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      store.write_base(record("closed"))
      store.prune("2026-08-30", pruned_at: NOW, reason: "operator_confirmed")
      entry = {
        "identity" => "fact:one", "source" => "github", "kind" => "fact",
        "observed_at" => "2026-08-31T07:59:00Z", "reason" => "projection was pruned"
      }

      first = store.discard_pruned(
        "2026-08-30", entries: [ entry ], source_frontiers: { "github" => 1 },
        discarded_at: "2026-08-31T08:00:00Z"
      )
      replay = store.discard_pruned(
        "2026-08-30", entries: [ entry ], source_frontiers: { "github" => 1 },
        discarded_at: "2026-08-31T09:00:00Z"
      )

      assert_equal 1, replay.fetch("discards").size
      assert_equal first.dig("discards", 0, "discard_id"), replay.dig("discards", 0, "discard_id")
      assert_equal "2026-08-31T07:59:00.000000Z", replay.dig("discards", 0, "observed_at")
      assert_equal "2026-08-31T08:00:00.000000Z", replay.dig("discards", 0, "discarded_at")
    end
  end

  def test_invalid_and_corrupt_store_inputs_return_typed_errors
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      assert_raises(Hive::DailyDigest::InvalidRecord) { store.read("bad-date") }
      assert_raises(Hive::DailyDigest::InvalidRecord) do
        store.send(:normalize_time, "bad-time")
      end
      assert_raises(Hive::DailyDigest::InvalidRecord) do
        store.send(:normalize_discard, nil, discarded_at: NOW)
      end
      assert_raises(Hive::DailyDigest::InvalidRecord) do
        store.send(:merge_frontiers, {}, Object.new)
      end

      path = store.base_path("2026-08-30")
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, "not-json")
      assert_raises(Hive::DailyDigest::Store::Error) do
        store.send(:read_json, path)
      end
    end
  end

  def test_symlinked_lock_is_rejected
    with_tmp_dir do |dir|
      root = File.join(dir, "digest")
      FileUtils.mkdir_p(root)
      target = File.join(dir, "lock-target")
      File.binwrite(target, "")
      File.symlink(target, File.join(root, ".store.lock"))
      store = Hive::DailyDigest::Store.new(root: root)

      assert_raises(Hive::DailyDigest::Store::UnsafePath) { store.dates }
    end
  end

  def test_conflicting_pruned_discard_is_rejected
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      entry = { "identity" => "fact:one", "source" => "github", "kind" => "fact" }
      normalized = store.send(:normalize_discard, entry, discarded_at: NOW)
      conflicting = normalized.merge("reason" => "different stored reason")
      tombstone = { "discards" => [ conflicting ], "source_frontiers" => {} }
      store.define_singleton_method(:read_json) { |_path| tombstone }
      store.define_singleton_method(:write_json) { |*_args| flunk "conflict must not write" }

      assert_raises(Hive::DailyDigest::Store::Conflict) do
        store.discard_pruned(
          "2026-08-30", entries: [ entry ], source_frontiers: {}, discarded_at: NOW
        )
      end
    end
  end

  private

  def record(lifecycle, items: [], completeness: "complete", content: nil, gaps: [])
    {
      "schema" => "hive-digest-record",
      "schema_version" => 1,
      "interval_id" => "a" * 64,
      "local_date" => "2026-08-30",
      "sequence" => 1,
      "time_zone" => "Europe/London",
      "starts_at" => "2026-08-29T23:00:00.000000Z",
      "ends_at" => "2026-08-30T23:00:00.000000Z",
      "duration_seconds" => 86_400,
      "boundary_kind" => "calendar_day",
      "cutover" => nil,
      "lifecycle" => lifecycle,
      "closed_at" => lifecycle == "closed" ? "2026-08-31T00:00:00.000000Z" : nil,
      "completeness" => completeness,
      "content" => content || (items.empty? ? "empty" : "non_empty"),
      "last_materialized_at" => NOW.iso8601(6),
      "projects" => [ { "project_id" => "project-1", "name" => "demo" } ],
      "items" => items,
      "attention" => [],
      "gaps" => gaps,
      "source_frontiers" => {}
    }
  end

  def item(kind)
    { "fact_id" => "fact:#{kind}", "kind" => kind, "project_id" => "project-1",
      "occurred_at" => NOW.iso8601(6), "observed_at" => NOW.iso8601(6) }
  end

  def gap
    { "gap_id" => "gap:github:demo", "source" => "github", "scope" => "demo",
      "reason" => "unavailable", "observed_at" => NOW.iso8601(6), "freshness_at" => nil }
  end

  def amendment(id, amended_at: "2026-08-31T08:00:01Z", gaps: [], resolved_gap_ids: [])
    {
      "amendment_id" => "amendment:#{id}", "kind" => "late_observation", "source" => "test",
      "event_at" => nil, "observed_at" => "2026-08-31T08:00:00Z",
      "amended_at" => amended_at, "items" => [], "gaps" => gaps,
      "resolved_gap_ids" => resolved_gap_ids
    }
  end
end
