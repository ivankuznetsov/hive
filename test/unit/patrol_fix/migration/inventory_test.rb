require "test_helper"
require "hive/patrol_fix/migration/inventory"

class PatrolFixMigrationInventoryTest < Minitest::Test
  DIGEST = "a" * 64

  class Port
    attr_reader :cursors

    def initialize(pages, opaque: [])
      @pages = pages
      @opaque = opaque
      @cursors = []
    end

    def migration_page(limit:, cursor: nil)
      @cursors << [ limit, cursor ]
      @pages.fetch(cursor)
    end

    def opaque_v3_entries
      @opaque
    end
  end

  def test_drains_every_cursor_page_and_preserves_opaque_v3_separately
    first = candidate("ordinary_finding", "finding-1", "root-a")
    second = candidate("architecture_finding", "job-1:thesis-1", "root-a")
    port = Port.new({
      nil => page([ first ], cursor: "next", token: "a" * 64),
      "next" => page([ second ], cursor: nil, token: "a" * 64)
    },
      opaque: [
        { "source_id" => "old.json", "canonical_digest" => "b" * 64,
          "byte_size" => 17 }
      ]
    )

    result = Hive::PatrolFix::Migration::Inventory.new(
      source_ports: [ port ], page_size: 1
    ).capture

    assert_equal [ [ 1, nil ], [ 1, "next" ] ], port.cursors
    assert_equal [ second, first ], result.fetch("candidates")
    assert_equal 2, result.fetch("count")
    assert_equal 1, result.dig("opaque_v3", "count")
    assert_equal "old.json", result.dig("opaque_v3", "entries", 0, "source_id")
  end

  def test_rejects_a_cursor_page_from_a_different_frozen_snapshot
    port = Port.new({
      nil => page([ candidate("ordinary_finding", "finding-1", "root-a") ],
                  cursor: "next", token: "a" * 64),
      "next" => page([], cursor: nil, token: "b" * 64)
    })

    assert_raises(Hive::PatrolFix::Migration::Inventory::InvalidInventory) do
      Hive::PatrolFix::Migration::Inventory.new(
        source_ports: [ port ], page_size: 1
      ).capture
    end
  end

  def test_rejects_duplicate_source_identity_instead_of_overwriting_it
    item = candidate("ordinary_finding", "finding-1", "root-a")
    port = Port.new({ nil => page([ item, item ], cursor: nil, token: "f" * 64) })

    assert_raises(Hive::PatrolFix::Migration::Inventory::InvalidInventory) do
      Hive::PatrolFix::Migration::Inventory.new(source_ports: [ port ]).capture
    end
  end

  private

  def page(entries, cursor:, token:)
    {
      "entries" => entries,
      "next_cursor" => cursor,
      "snapshot_token" => token
    }
  end

  def candidate(kind, id, root)
    {
      "source_kind" => kind,
      "source_id" => id,
      "source_schema" => "example/v1",
      "canonical_digest" => DIGEST.sub(/a/, id.end_with?("1") ? "a" : "c"),
      "authority_state" => "accepted",
      "semantic_root" => root,
      "observations" => [],
      "blocking_reason" => nil
    }
  end
end
