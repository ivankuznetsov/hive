require "test_helper"
require "tmpdir"
require "hive/patrol_fix/migration/cutover_state"
require "hive/patrol_fix/migration/disposition_manifest"
require "hive/patrol/finding"
require "hive/patrol/state_store"
require "hive/refactor_patrol/job_store"
require "json_schemer"

class PatrolFixMigrationCutoverStateTest < Minitest::Test
  NOW = Time.utc(2026, 8, 21, 1)

  def test_persists_preflight_and_derives_source_gates_only_after_fence
    Dir.mktmpdir do |root|
      store = Hive::PatrolFix::Migration::CutoverState.new(root: root)
      state = store.preflight!(
        manifest: manifest,
        source_epochs: { "ordinary_patrol" => 7, "architecture_patrol" => 7 },
        now: NOW
      )

      assert_equal "preflight", state.fetch("status")
      refute store.gate_for("ordinary_patrol").enabled?

      fenced = store.fence!(
        expected_source_epochs: state.fetch("source_epochs"),
        fenced_source_epochs: { "ordinary_patrol" => 8, "architecture_patrol" => 8 },
        now: NOW + 1
      )

      assert_equal "fenced", fenced.fetch("status")
      restarted = Hive::PatrolFix::Migration::CutoverState.new(root: root)
      assert restarted.gate_for("ordinary_patrol").enabled?
      assert_equal "8", restarted.gate_for("ordinary_patrol").epoch
      assert_equal manifest.canonical_bytes, restarted.manifest.canonical_bytes
    end
  end

  def test_persisted_state_matches_the_registered_cutover_schema
    Dir.mktmpdir do |root|
      store = Hive::PatrolFix::Migration::CutoverState.new(root: root)
      document = store.preflight!(
        manifest: manifest,
        source_epochs: { "ordinary_patrol" => 7, "architecture_patrol" => 7 },
        now: NOW
      )
      schema = JSONSchemer.schema(JSON.parse(File.read(
        Hive::Schemas.schema_path("hive-patrol-fix-migration-cutover-state")
      )))

      assert schema.valid?(document), schema.validate(document).to_a.inspect
    end
  end

  def test_effect_arm_makes_cutover_forward_only_and_group_replay_is_exact
    Dir.mktmpdir do |root|
      store = fenced_store(root)
      store.start_applying!(now: NOW + 2)
      intent = {
        "group_id" => "group-one", "candidate_set_digest" => "c" * 64,
        "route" => "create_or_attach_inbox", "canonical_identity" => nil,
        "members" => [ "ordinary_finding:finding-1" ]
      }
      store.begin_group!(intent, now: NOW + 3)
      store.arm_group_effect!("group-one", now: NOW + 4)

      refute store.rollback_allowed?
      assert_raises(Hive::PatrolFix::Migration::CutoverState::ForwardOnly) do
        store.rollback!(source_epochs: { "ordinary_patrol" => 9,
                                         "architecture_patrol" => 9 }, now: NOW + 5)
      end
      assert_equal intent, store.begin_group!(intent, now: NOW + 6)
      assert_raises(Hive::PatrolFix::Migration::CutoverState::Conflict) do
        store.begin_group!(intent.merge("route" => "done_existing_pr"), now: NOW + 7)
      end
    end
  end

  def test_rejects_acknowledgement_count_or_member_drift_on_read
    Dir.mktmpdir do |root|
      store = fenced_store(root)
      store.start_applying!(now: NOW + 2)
      intent = {
        "group_id" => "group-one", "candidate_set_digest" => "c" * 64,
        "route" => "blocked_source", "canonical_identity" => nil,
        "members" => [ "ordinary_finding:finding-1" ]
      }
      store.begin_group!(intent, now: NOW + 3)
      store.acknowledge_member!(
        "group-one", member: "ordinary_finding:finding-1",
        receipt_id: "blocked-receipt", now: NOW + 4
      )
      path = File.join(root, "state.json")
      document = JSON.parse(File.binread(path))
      document["acknowledgement_count"] = 0
      File.binwrite(path, Hive::PatrolFix.canonical_json(document))

      assert_raises(Hive::PatrolFix::Migration::CutoverState::CorruptState) do
        Hive::PatrolFix::Migration::CutoverState.new(root: root).read
      end
    end
  end

  def test_rollback_preflight_can_be_replaced_after_existing_epoch_advances
    Dir.mktmpdir do |root|
      store = fenced_store(root)
      store.rollback!(
        source_epochs: { "ordinary_patrol" => 9, "architecture_patrol" => 9 },
        now: NOW + 2
      )
      assert_equal({ "ordinary_patrol" => 9, "architecture_patrol" => 9 },
                   store.read.fetch("source_epochs"))
      changed_document = Hive::PatrolFix.deep_copy(manifest.to_h)
      changed_document["observation_dispositions"] = [
        { "kind" => "task", "identity" => "after-rollback",
          "group_id" => "group-one", "route" => "observed", "reason" => "new" }
      ]
      changed = Hive::PatrolFix::Migration::DispositionManifest.new(changed_document)

      state = store.preflight!(
        manifest: changed,
        source_epochs: { "ordinary_patrol" => 9, "architecture_patrol" => 9 },
        now: NOW + 3
      )

      assert_equal Digest::SHA256.hexdigest(changed.canonical_bytes),
                   state.fetch("manifest_digest")
      assert_equal changed.canonical_bytes, store.manifest.canonical_bytes
    end
  end

  def test_pristine_preflight_can_replace_manifest_at_same_epoch_after_guard_race
    Dir.mktmpdir do |root|
      store = Hive::PatrolFix::Migration::CutoverState.new(root: root)
      store.preflight!(
        manifest: manifest,
        source_epochs: { "ordinary_patrol" => 7, "architecture_patrol" => 7 },
        now: NOW
      )
      changed_document = Hive::PatrolFix.deep_copy(manifest.to_h)
      changed_document["observation_dispositions"] = [
        { "kind" => "task", "identity" => "boundary-acceptance",
          "group_id" => "group-one", "route" => "observed", "reason" => "new" }
      ]
      changed = Hive::PatrolFix::Migration::DispositionManifest.new(changed_document)

      state = store.preflight!(
        manifest: changed,
        source_epochs: { "ordinary_patrol" => 7, "architecture_patrol" => 7 },
        now: NOW + 1
      )

      assert_equal Digest::SHA256.hexdigest(changed.canonical_bytes),
                   state.fetch("manifest_digest")
      assert_equal changed.canonical_bytes, store.manifest.canonical_bytes
    end
  end

  def test_normal_source_stores_reconstruct_enabled_cutover_gates_after_restart
    Dir.mktmpdir do |project|
      hive_state = File.join(project, ".hive-state")
      store = Hive::PatrolFix::Migration::CutoverState.new(
        root: File.join(hive_state, "patrol-fix", "migration")
      )
      preflight = store.preflight!(
        manifest: manifest,
        source_epochs: { "ordinary_patrol" => 7, "architecture_patrol" => 7 },
        now: NOW
      )
      ordinary = Hive::Patrol::StateStore.new(
        project, hive_state_path: hive_state
      )
      architecture = Hive::RefactorPatrol::JobStore.new(
        project, hive_state_path: hive_state
      )
      refute ordinary.patrol_fix_admission_outbox.enabled?
      refute architecture.patrol_fix_admission_outbox.enabled?
      store.fence!(
        expected_source_epochs: preflight.fetch("source_epochs"),
        fenced_source_epochs: {
          "ordinary_patrol" => 8, "architecture_patrol" => 8
        }, now: NOW + 1
      )

      assert ordinary.patrol_fix_admission_outbox.enabled?
      assert architecture.patrol_fix_admission_outbox.enabled?
      assert_equal "8", ordinary.patrol_fix_admission_outbox.store
        .instance_variable_get(:@gate).epoch
      assert_equal "8", architecture.patrol_fix_admission_outbox.store
        .instance_variable_get(:@gate).epoch
      ordinary.ensure!
      ordinary.write_finding(ordinary_finding)
      pending = ordinary.patrol_fix_admission_outbox.pending
      assert_equal [ "finding-after-fence" ],
                   pending.map { |entry| entry.dig("snapshot", "identity") }
    end
  end

  private

  def manifest
    @manifest ||= Hive::PatrolFix::Migration::DispositionManifest.build(
      inventory: inventory,
      reconciliation: {
        "groups" => [ group ], "dispositions" => [ disposition ],
        "observation_dispositions" => []
      }
    )
  end

  def candidate
    {
      "source_kind" => "ordinary_finding", "source_id" => "finding-1",
      "source_schema" => "hive-patrol-finding/v1", "canonical_digest" => "e" * 64,
      "authority_state" => "accepted", "semantic_root" => "refresh",
      "observations" => [], "blocking_reason" => nil
    }
  end

  def ordinary_finding
    Hive::Patrol::Finding.new(
      id: "finding-after-fence", feature_id: "refresh", category: "bug",
      severity: "high", confidence: "high", title: "Repair refresh",
      description: "Refresh fails", recommendation: "Consolidate recovery",
      scope: "feature", contract: "Refresh remains usable", impact: "Sessions fail",
      root_cause: "Two owners race", reproduction: "Run the refresh spec",
      validation: "Run test/refresh_test.rb", evidence: [ "Reachable failure" ],
      fingerprint: "refresh-root", validation_key: "refresh-v1",
      target_sha: "1" * 40, lifecycle_state: "active",
      lifecycle_reason: "admitted", lifecycle_updated_at: NOW.iso8601
    )
  end

  def inventory
    {
      "count" => 1,
      "root_digest" =>
        Hive::PatrolFix::Migration::DispositionManifest.inventory_root([ candidate ]),
      "candidates" => [ candidate ],
      "opaque_v3" => {
        "count" => 0,
        "root_digest" => Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json([])),
        "entries" => []
      }
    }
  end

  def group
    ref = "ordinary_finding:finding-1"
    {
      "group_id" => "group-one",
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
  end

  def disposition
    candidate.slice("source_kind", "source_id", "source_schema", "canonical_digest").merge(
      "group_id" => "group-one", "route" => "create_or_attach_inbox",
      "canonical_identity" => nil, "blocking_reason" => nil
    )
  end

  def fenced_store(root)
    store = Hive::PatrolFix::Migration::CutoverState.new(root: root)
    state = store.preflight!(
      manifest: manifest,
      source_epochs: { "ordinary_patrol" => 7, "architecture_patrol" => 7 },
      now: NOW
    )
    store.fence!(
      expected_source_epochs: state.fetch("source_epochs"),
      fenced_source_epochs: { "ordinary_patrol" => 8, "architecture_patrol" => 8 },
      now: NOW + 1
    )
    store
  end
end
