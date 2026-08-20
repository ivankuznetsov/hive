require "test_helper"
require "hive/patrol_fix/migration/disposition_manifest"
require "hive/patrol_fix/migration/semantic_group"
require "json_schemer"

class PatrolFixMigrationDispositionManifestTest < Minitest::Test
  def test_manifest_is_byte_stable_and_reconstructs_count_and_root_digest
    inventory = inventory_payload
    reconciliation = reconciliation_payload

    first = Hive::PatrolFix::Migration::DispositionManifest.build(
      inventory: inventory, reconciliation: reconciliation
    )
    second = Hive::PatrolFix::Migration::DispositionManifest.build(
      inventory: inventory, reconciliation: reconciliation
    )

    assert_equal first.canonical_bytes, second.canonical_bytes
    assert first.verify!
    assert_equal 1, first.to_h.dig("integrity", "inventory_count")
    assert_equal first.to_h.dig("inventory", "root_digest"),
                 first.to_h.dig("integrity", "reconstructed_root_digest")
    schema = JSONSchemer.schema(JSON.parse(File.read(
      Hive::Schemas.schema_path("hive-patrol-fix-migration-disposition-manifest")
    )))
    assert schema.valid?(first.to_h), schema.validate(first.to_h).to_a.inspect
  end

  def test_opaque_v3_count_and_digest_are_reconstructed
    inventory = inventory_payload
    inventory["opaque_v3"] = {
      "count" => 1, "root_digest" => "0" * 64,
      "entries" => [
        { "source_id" => "jobs/old.json", "canonical_digest" => "e" * 64,
          "byte_size" => 12 }
      ]
    }

    assert_raises(Hive::PatrolFix::Migration::DispositionManifest::IntegrityError) do
      Hive::PatrolFix::Migration::DispositionManifest.build(
        inventory: inventory, reconciliation: reconciliation_payload
      )
    end
  end

  def test_missing_or_duplicate_disposition_fails_closed
    inventory = inventory_payload
    missing = reconciliation_payload.merge("dispositions" => [])
    assert_raises(Hive::PatrolFix::Migration::DispositionManifest::IntegrityError) do
      Hive::PatrolFix::Migration::DispositionManifest.build(
        inventory: inventory, reconciliation: missing
      )
    end

    duplicate = reconciliation_payload
    duplicate = duplicate.merge(
      "dispositions" => duplicate.fetch("dispositions") * 2
    )
    assert_raises(Hive::PatrolFix::Migration::DispositionManifest::IntegrityError) do
      Hive::PatrolFix::Migration::DispositionManifest.build(
        inventory: inventory, reconciliation: duplicate
      )
    end
  end

  def test_disposition_must_match_its_groups_canonical_decision
    inventory = inventory_payload
    reconciliation = reconciliation_payload
    tampered = reconciliation.fetch("dispositions").first.merge(
      "route" => "create_or_attach_inbox",
      "canonical_identity" => "task-elsewhere"
    )

    assert_raises(Hive::PatrolFix::Migration::DispositionManifest::IntegrityError) do
      Hive::PatrolFix::Migration::DispositionManifest.build(
        inventory: inventory,
        reconciliation: reconciliation.merge("dispositions" => [ tampered ])
      )
    end
  end

  private

  def candidate
    {
      "source_kind" => "ordinary_finding", "source_id" => "finding-1",
      "source_schema" => "hive-patrol-finding/v1", "canonical_digest" => "a" * 64,
      "authority_state" => "blocked", "semantic_root" => nil,
      "observations" => [], "blocking_reason" => "source record is corrupt"
    }
  end

  def inventory_payload
    item = candidate
    root = Hive::PatrolFix::Migration::DispositionManifest.inventory_root([ item ])
    {
      "candidates" => [ item ], "count" => 1, "root_digest" => root,
      "opaque_v3" => {
        "count" => 0,
        "root_digest" => Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json([])),
        "entries" => []
      }
    }
  end

  def reconciliation_payload
    ref = "ordinary_finding:finding-1"
    group = Hive::PatrolFix::Migration::SemanticGroup.build([ candidate ]).fetch(0)
    {
      "groups" => [
        group.merge(
          "canonical_decision" => {
            "route" => "blocked_source", "canonical_identity" => nil,
            "planned_mutations" => [], "observation_ids" => []
          }
        )
      ],
      "dispositions" => [
        {
          "source_kind" => "ordinary_finding", "source_id" => "finding-1",
          "source_schema" => "hive-patrol-finding/v1", "canonical_digest" => "a" * 64,
          "group_id" => group.fetch("group_id"), "route" => "blocked_source",
          "canonical_identity" => nil, "blocking_reason" => "source record is corrupt"
        }
      ],
      "observation_dispositions" => []
    }
  end
end
