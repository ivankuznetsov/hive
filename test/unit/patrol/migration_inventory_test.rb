require "test_helper"
require "hive/patrol/state_store"
require "hive/patrol/migration_inventory"

class PatrolMigrationInventoryTest < Minitest::Test
  include HiveTestHelper

  def test_translates_active_findings_and_retains_corrupt_sources_as_blocked
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.with_cycle_lock { nil }
      store.write_finding(finding("active", "active"))
      store.write_finding(finding("resolved", "resolved"))
      File.write(File.join(store.root, "findings", "corrupt.json"), "{")
      port = store.patrol_fix_migration_inventory

      page = port.migration_page(limit: 10)

      assert_nil page.fetch("next_cursor")
      assert_equal %w[active corrupt],
                   page.fetch("entries").map { |entry| entry.fetch("source_id") }
      active, corrupt = page.fetch("entries")
      assert_equal "accepted", active.fetch("authority_state")
      assert_equal "shared-root", active.fetch("semantic_root")
      assert_equal "blocked", corrupt.fetch("authority_state")
      assert_match(/corrupt or unsupported/, corrupt.fetch("blocking_reason"))
    end
  end

  def test_translates_existing_ordinary_claims_and_publication_custody
    with_tmp_dir do |dir|
      finding = finding("active", "active")
      support = {
        "fingerprints" => {
          finding.fingerprint => {
            "state" => "reconciliation_pending",
            "branch" => "hive-patrol/feature-shared",
            "pr_url" => "https://github.com/acme/demo/pull/42",
            "publication_binding" => {
              "receipt_id" => "receipt-#{'1' * 64}",
              "intent_id" => "intent-#{'2' * 64}",
              "occurrence_id" => "occ-#{'3' * 64}",
              "repository" => "acme/demo",
              "base_branch" => "main",
              "branch" => "hive-patrol/feature-shared",
              "pr_url" => "https://github.com/acme/demo/pull/42",
              "pr_state" => "OPEN",
              "patch_id" => "patch-1",
              "worktree_path" => File.join(dir, "worktree"),
              "base_sha" => "a" * 40,
              "base_oid" => "a" * 40,
              "head_sha" => "b" * 40,
              "head_oid" => "b" * 40
            }
          }
        },
        "occurrences" => [
          {
            "occurrence_id" => "occ-#{'4' * 64}",
            "phase" => "reserved",
            "effects" => {}
          }
        ]
      }
      store = Struct.new(:support) do
        def patrol_fix_migration_page(limit:, cursor: nil)
          raise "unexpected cursor" if cursor

          {
            "entries" => [
              {
                "source_id" => "active",
                "source_schema" => "hive-patrol-finding/v1",
                "canonical_digest" => "a" * 64,
                "record" => PatrolMigrationInventoryTest.new(
                  "placeholder"
                ).send(:finding, "active", "active").to_h,
                "error" => nil
              }
            ],
            "next_cursor" => nil,
            "snapshot_token" => "f" * 64
          }
        end

        def patrol_fix_migration_support_snapshot = support
      end.new(support)
      port = Hive::Patrol::MigrationInventory.new(store)

      candidate = port.migration_page(limit: 10).fetch("entries").fetch(0)
      kinds = candidate.fetch("observations").map { |entry| entry.fetch("kind") }

      assert_equal "claimed", candidate.fetch("authority_state")
      assert_includes kinds, "claim"
      assert_includes kinds, "pull_request"
      assert_includes kinds, "branch"
      assert_includes kinds, "validated_patch"
    end
  end

  def test_real_state_store_support_reader_is_strict_and_read_only
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.with_cycle_lock { nil }
      store.write_finding(finding("active", "active"))
      store.send(:raw_write_fingerprints,
        "shared-root" => {
          "state" => "open",
          "branch" => "hive-patrol/feature-shared",
          "pr_url" => "https://github.com/acme/demo/pull/42",
          "patch_id" => "patch-1"
        }
      )
      now = Time.utc(2026, 8, 21)
      capture = Hive::Modules::Migration::PatrolCapture.build(
        module_name: "patrol",
        project: {
          "project_id" => "project-1", "name" => "demo",
          "repository" => "acme/demo"
        },
        trigger: { "kind" => "direct", "id" => "migration-test" },
        reservation: { "kind" => "ordinary", "id" => "reservation-1" },
        owner: "legacy", owner_epoch: 1,
        selection_input: { "kind" => "operation", "operation" => "test" },
        selection: Hive::Modules::Migration::PatrolDecisionProjection.build(
          module_name: "patrol", rationale: "due"
        ),
        outcome_class: nil, outcome: nil,
        occurred_at: now, recorded_at: now
      )
      store.reserve_occurrence!(capture, now: now)

      candidate = store.patrol_fix_migration_inventory
                       .migration_page(limit: 10)
                       .fetch("entries").fetch(0)

      assert_equal "claimed", candidate.fetch("authority_state")
      assert_equal %w[branch claim pull_request validated_patch],
                   candidate.fetch("observations")
                            .map { |entry| entry.fetch("kind") }.sort

      File.write(File.join(store.root, "fingerprints.json"), "{")
      assert_raises(Hive::ConfigError) do
        store.patrol_fix_migration_inventory.migration_page(limit: 10)
      end
    end
  end

  private

  def finding(id, state)
    Hive::Patrol::Finding.new(
      id: id, feature_id: "feature", category: "bug", severity: "medium",
      confidence: "high", title: id, description: "evidence",
      fingerprint: "shared-root", lifecycle_state: state,
      lifecycle_updated_at: "2026-08-21T00:00:00Z"
    )
  end
end
