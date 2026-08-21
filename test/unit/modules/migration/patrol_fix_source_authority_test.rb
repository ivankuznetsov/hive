require "test_helper"
require "hive/modules/migration/patrol_fix_source_authority"
require "hive/patrol/state_store"
require "hive/patrol_fix/migration/disposition_manifest"

class PatrolFixSourceAuthorityTest < Minitest::Test
  include HiveTestHelper

  class UnusedArchitectureStore
    def patrol_fix_migration_inventory(**) = raise("must not scan Architecture inventory")
  end

  class ArchitectureOutbox
    def initialize(snapshot) = @snapshot = snapshot
    def migration_snapshot(_aggregate, _disposition) = @snapshot
  end

  class ArchitectureStore
    attr_reader :patrol_fix_admission_outbox

    def initialize(entry, snapshot)
      @entry = entry
      @patrol_fix_admission_outbox = ArchitectureOutbox.new(snapshot)
    end

    def patrol_fix_migration_source(job_id)
      raise "wrong job" unless job_id == @entry.fetch("source_id")
      @entry
    end

    def patrol_fix_migration_inventory(**) = raise("must not scan full inventory")
  end

  def test_ordinary_snapshot_re_reads_exact_source_bytes_without_full_inventory_scan
    with_tmp_dir do |project|
      store = Hive::Patrol::StateStore.new(project)
      store.with_cycle_lock { nil }
      finding = Hive::Patrol::Finding.new(
        id: "finding-1", feature_id: "feature", category: "bug",
        severity: "medium", confidence: "high", title: "Repair refresh",
        description: "Refresh fails", fingerprint: "refresh-root",
        target_sha: "a" * 40, lifecycle_state: "active",
        lifecycle_updated_at: "2026-08-21T00:00:00Z"
      )
      store.write_finding(finding)
      candidate = store.patrol_fix_migration_inventory
                       .migration_page(limit: 10).fetch("entries").fetch(0)
      authority = Hive::Modules::Migration::PatrolFixSourceAuthority.new(
        ordinary_store: store, architecture_store: UnusedArchitectureStore.new,
        manifest: manifest(candidate)
      )

      assert_equal "finding-1",
                   authority.snapshot_for("ordinary_finding:finding-1").to_h.fetch("identity")

      finding.title = "Changed after preflight"
      store.write_finding(finding)
      assert_raises(Hive::Modules::Migration::PatrolFixSourceAuthority::StaleSource) do
        authority.snapshot_for("ordinary_finding:finding-1")
      end
    end
  end

  def test_architecture_snapshot_recomputes_candidate_digest_from_job_bytes_and_identity
    snapshot = source_snapshot
    aggregate = {
      "job_id" => "job-1",
      "dispositions" => {
        "fix" => [ { "id" => "thesis-1" } ], "discuss" => [], "dismiss" => []
      }
    }
    entry = {
      "source_id" => "job-1", "source_schema" => "hive-refactor-patrol-job/v4",
      "canonical_digest" => "a" * 64, "record" => aggregate, "error" => nil
    }
    candidate = architecture_candidate(entry)
    authority = Hive::Modules::Migration::PatrolFixSourceAuthority.new(
      ordinary_store: Object.new,
      architecture_store: ArchitectureStore.new(entry, snapshot),
      manifest: manifest(candidate)
    )

    assert_equal snapshot.to_h,
                 authority.snapshot_for("architecture_finding:job-1:thesis-1").to_h

    changed = entry.merge("canonical_digest" => "b" * 64)
    stale = Hive::Modules::Migration::PatrolFixSourceAuthority.new(
      ordinary_store: Object.new,
      architecture_store: ArchitectureStore.new(changed, snapshot),
      manifest: manifest(candidate)
    )
    assert_raises(Hive::Modules::Migration::PatrolFixSourceAuthority::StaleSource) do
      stale.snapshot_for("architecture_finding:job-1:thesis-1")
    end
  end

  private

  def architecture_candidate(entry)
    identity = "job-1:thesis-1"
    {
      "source_kind" => "architecture_finding", "source_id" => identity,
      "source_schema" => entry.fetch("source_schema"),
      "canonical_digest" => Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(
        "job_digest" => entry.fetch("canonical_digest"), "source_identity" => identity
      )),
      "authority_state" => "accepted", "semantic_root" => "root",
      "observations" => [], "blocking_reason" => nil
    }
  end

  def manifest(candidate)
    ref = "#{candidate.fetch('source_kind')}:#{candidate.fetch('source_id')}"
    group = {
      "group_id" => "group-#{'c' * 32}",
      "candidate_set_digest" => Digest::SHA256.hexdigest(
        Hive::PatrolFix.canonical_json([ [ ref, candidate.fetch("canonical_digest") ] ])
      ),
      "members" => [ ref ], "canonical_source" => ref,
      "semantic_decision" => {},
      "canonical_decision" => {
        "route" => "create_or_attach_inbox", "canonical_identity" => nil,
        "planned_mutations" => [], "observation_ids" => []
      }
    }
    Hive::PatrolFix::Migration::DispositionManifest.build(
      inventory: {
        "candidates" => [ candidate ], "count" => 1,
        "root_digest" => Hive::PatrolFix::Migration::DispositionManifest.inventory_root([ candidate ]),
        "opaque_v3" => {
          "count" => 0,
          "root_digest" => Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json([])),
          "entries" => []
        }
      },
      reconciliation: {
        "groups" => [ group ],
        "dispositions" => [ candidate.slice(
          "source_kind", "source_id", "source_schema", "canonical_digest"
        ).merge(
          "group_id" => group.fetch("group_id"),
          "route" => "create_or_attach_inbox",
          "canonical_identity" => nil, "blocking_reason" => nil
        ) ],
        "observation_dispositions" => []
      }
    )
  end

  def source_snapshot
    Hive::PatrolFix::SourceSnapshot.build(
      engine: "architecture_patrol", identity: "job-1:thesis-1",
      title: "Repair refresh", summary: "Refresh fails", target_revision: "a" * 40,
      evidence: [ "Evidence" ], affected_code: [ "lib/refresh.rb" ],
      reproduction_guidance: "Reproduce", discovery_run: "job-1",
      semantic_lineage: [ "root" ], aliases: [], external_issues: [],
      existing_pull_requests: [], accepted_at: "2026-08-21T00:00:00Z"
    )
  end
end
