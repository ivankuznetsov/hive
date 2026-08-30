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

  def test_prune_removes_projection_but_keeps_owner_private_tombstone
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      store.write_base(record("closed"))
      receipt = store.prune("2026-08-30", pruned_at: NOW, reason: "operator_confirmed")

      refute File.exist?(store.base_path("2026-08-30"))
      assert_equal "pruned", store.read("2026-08-30").fetch("lifecycle")
      assert_equal receipt.fetch("receipt_id"), store.read("2026-08-30").fetch("receipt_id")
      assert_equal 0o600, File.stat(store.tombstone_path("2026-08-30")).mode & 0o777
    end
  end

  private

  def record(lifecycle, items: [], completeness: "complete", content: nil, gaps: [])
    {
      "schema" => "hive-digest-record",
      "schema_version" => 1,
      "local_date" => "2026-08-30",
      "sequence" => 1,
      "time_zone" => "Europe/London",
      "starts_at" => "2026-08-29T23:00:00.000000Z",
      "ends_at" => "2026-08-30T23:00:00.000000Z",
      "boundary_kind" => "calendar_day",
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
end
