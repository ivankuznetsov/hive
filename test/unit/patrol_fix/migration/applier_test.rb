require "test_helper"
require "tmpdir"
require "hive/patrol_fix/migration/applier"
require "hive/patrol_fix/migration/cutover_state"
require "hive/patrol_fix/migration/disposition_manifest"

class PatrolFixMigrationApplierTest < Minitest::Test
  NOW = Time.utc(2026, 8, 21, 2)

  def test_revalidates_then_fences_materializes_and_acknowledges_source_last
    Dir.mktmpdir do |root|
      events = []
      store = Hive::PatrolFix::Migration::CutoverState.new(root: root)
      applier = Hive::PatrolFix::Migration::Applier.new(
        state: store, manifest: manifest,
        inventory_port: -> { events << :inventory; inventory },
        epoch_port: epoch_port(events),
        group_materializer: lambda do |group|
          events << [ :materialize, group.fetch("group_id") ]
          { "slug" => "repair-refresh", "generation" => 1,
            "evidence_digest" => "d" * 64 }
        end,
        source_acknowledger: lambda do |member, task|
          events << [ :ack, member, task.fetch("slug") ]
          "ack-#{member}"
        end,
        authority_verifier: lambda do |**|
          events << :verify
          final_verification
        end,
        clock: -> { NOW }
      )

      result = applier.call

      assert_equal "committed", result.fetch("status")
      assert_operator events.index(:inventory), :<, events.index(:fence)
      assert_operator events.index(:fence_guard_inventory), :<, events.index(:fence)
      assert_operator events.index([ :materialize, "group-one" ]), :<,
                      events.index([ :ack, "ordinary_finding:finding-1", "repair-refresh" ])
      assert_operator events.index(:verify), :<, events.index(:activate)
      assert_equal 1, events.count { |event| event == [ :materialize, "group-one" ] }
      assert_equal 3, events.count(:inventory),
                   "preflight, locked fence, and final verification must reread sources"
    end
  end

  def test_restart_rejects_a_caller_manifest_that_differs_from_durable_preflight
    Dir.mktmpdir do |root|
      state = Hive::PatrolFix::Migration::CutoverState.new(root: root)
      preflight = state.preflight!(
        manifest: manifest,
        source_epochs: { "ordinary_patrol" => 7, "architecture_patrol" => 7 },
        now: NOW
      )
      state.fence!(
        expected_source_epochs: preflight.fetch("source_epochs"),
        fenced_source_epochs: {
          "ordinary_patrol" => 8, "architecture_patrol" => 8
        }, now: NOW
      )
      changed = Hive::PatrolFix.deep_copy(manifest.to_h).merge(
        "observation_dispositions" => [
          { "kind" => "task", "identity" => "other", "group_id" => "group-one",
            "route" => "observed", "reason" => "different" }
        ]
      )
      changed_manifest = Hive::PatrolFix::Migration::DispositionManifest.new(changed)

      error = assert_raises(Hive::PatrolFix::Migration::Applier::StalePreflight) do
        Hive::PatrolFix::Migration::Applier.new(
          state: state, manifest: changed_manifest,
          inventory_port: -> { inventory }, epoch_port: epoch_port([]),
          group_materializer: ->(*) { flunk "must not materialize" },
          source_acknowledger: ->(*) { flunk "must not acknowledge" },
          authority_verifier: ->(**) { flunk "must not verify" }, clock: -> { NOW }
        ).call
      end

      assert_match(/durable manifest/, error.message)
    end
  end

  def test_rollback_preflight_accepts_a_rebuilt_manifest_with_a_new_source
    Dir.mktmpdir do |root|
      state = Hive::PatrolFix::Migration::CutoverState.new(root: root)
      preflight = state.preflight!(
        manifest: manifest,
        source_epochs: { "ordinary_patrol" => 7, "architecture_patrol" => 7 },
        now: NOW
      )
      state.fence!(
        expected_source_epochs: preflight.fetch("source_epochs"),
        fenced_source_epochs: {
          "ordinary_patrol" => 8, "architecture_patrol" => 8
        }, now: NOW
      )
      state.rollback!(
        source_epochs: { "ordinary_patrol" => 9, "architecture_patrol" => 9 },
        now: NOW
      )
      rebuilt_inventory = inventory_with_second_source
      rebuilt_manifest = manifest_for_inventory(rebuilt_inventory)
      events = []

      result = Hive::PatrolFix::Migration::Applier.new(
        state: state, manifest: rebuilt_manifest,
        inventory_port: -> { rebuilt_inventory },
        epoch_port: epoch_port(events, expected_epoch: 9),
        group_materializer: lambda do |group|
          { "slug" => "repair-#{group.fetch('group_id')}", "generation" => 1,
            "evidence_digest" => "d" * 64 }
        end,
        source_acknowledger: ->(member, _task) { "ack-#{member}" },
        authority_verifier: lambda do |**|
          {
            "inventory_count" => 2,
            "inventory_root_digest" => rebuilt_inventory.fetch("root_digest"),
            "disposition_count" => 2, "completed_group_count" => 2,
            "authority_digest" => "f" * 64
          }
        end,
        clock: -> { NOW }
      ).call

      assert_equal "committed", result.fetch("status")
      assert_equal({ "ordinary_patrol" => 9, "architecture_patrol" => 9 },
                   result.fetch("source_epochs"))
      assert_equal({ "ordinary_patrol" => 10, "architecture_patrol" => 10 },
                   result.fetch("fenced_source_epochs"))
      assert_equal rebuilt_manifest.canonical_bytes, state.manifest.canonical_bytes
    end
  end

  def test_blocked_group_acknowledges_every_source_without_materializing
    Dir.mktmpdir do |root|
      state = Hive::PatrolFix::Migration::CutoverState.new(root: root)
      blocked_document = Hive::PatrolFix.deep_copy(manifest.to_h)
      blocked_document["semantic_groups"][0]["canonical_decision"]["route"] =
        "blocked_source"
      blocked_document["dispositions"][0]["route"] = "blocked_source"
      blocked_manifest = Hive::PatrolFix::Migration::DispositionManifest.new(
        blocked_document
      )
      acknowledgements = []

      result = Hive::PatrolFix::Migration::Applier.new(
        state: state, manifest: blocked_manifest,
        inventory_port: -> { inventory }, epoch_port: epoch_port([]),
        group_materializer: ->(*) { flunk "blocked group must not materialize" },
        source_acknowledger: lambda do |member, outcome|
          acknowledgements << [ member, outcome.fetch("route") ]
          "blocked-receipt"
        end,
        authority_verifier: ->(**) { final_verification }, clock: -> { NOW }
      ).call

      assert_equal "committed", result.fetch("status")
      assert_equal [ [ "ordinary_finding:finding-1", "blocked_source" ] ],
                   acknowledgements
      assert_equal 1, result.fetch("acknowledgement_count")
    end
  end

  def test_live_claim_route_refuses_epoch_fence
    Dir.mktmpdir do |root|
      state = Hive::PatrolFix::Migration::CutoverState.new(root: root)
      claimed_document = Hive::PatrolFix.deep_copy(manifest.to_h)
      claimed_document["semantic_groups"][0]["canonical_decision"]["route"] =
        "wait_live_claim"
      claimed_document["dispositions"][0]["route"] = "wait_live_claim"
      claimed_manifest = Hive::PatrolFix::Migration::DispositionManifest.new(
        claimed_document
      )
      events = []

      assert_raises(Hive::PatrolFix::Migration::Applier::Blocked) do
        Hive::PatrolFix::Migration::Applier.new(
          state: state, manifest: claimed_manifest,
          inventory_port: -> { inventory }, epoch_port: epoch_port(events),
          group_materializer: ->(*) { flunk "must not materialize" },
          source_acknowledger: ->(*) { flunk "must not acknowledge" },
          authority_verifier: ->(**) { flunk "must not verify" }, clock: -> { NOW }
        ).call
      end

      refute_includes events, :fence
      assert_equal "preflight", state.read.fetch("status")
    end
  end

  def test_claim_only_change_is_detected_by_locked_fence_guard
    Dir.mktmpdir do |root|
      state = Hive::PatrolFix::Migration::CutoverState.new(root: root)
      reads = 0
      inventory_port = lambda do
        reads += 1
        next inventory if reads == 1

        changed = Hive::PatrolFix.deep_copy(inventory)
        changed["candidates"][0]["authority_state"] = "claimed"
        changed
      end
      events = []

      assert_raises(Hive::PatrolFix::Migration::Applier::StalePreflight) do
        Hive::PatrolFix::Migration::Applier.new(
          state: state, manifest: manifest,
          inventory_port: inventory_port, epoch_port: epoch_port(events),
          group_materializer: ->(*) { flunk "must not materialize" },
          source_acknowledger: ->(*) { flunk "must not acknowledge" },
          authority_verifier: ->(**) { flunk "must not verify" }, clock: -> { NOW }
        ).call
      end

      refute_includes events, :fence
      assert_equal "preflight", state.read.fetch("status")
    end
  end

  def test_replay_after_acknowledgement_checkpoint_failure_reuses_group_intent
    Dir.mktmpdir do |root|
      state = Hive::PatrolFix::Migration::CutoverState.new(root: root)
      materializations = 0
      acknowledgements = 0
      fail_once = true
      factory = lambda do
        Hive::PatrolFix::Migration::Applier.new(
          state: state, manifest: manifest,
          inventory_port: -> { inventory }, epoch_port: epoch_port([]),
          group_materializer: lambda do |_group|
            materializations += 1
            { "slug" => "repair-refresh", "generation" => 1,
              "evidence_digest" => "d" * 64 }
          end,
          source_acknowledger: lambda do |_member, _task|
            acknowledgements += 1
            if fail_once
              fail_once = false
              raise "ack unavailable"
            end
            "ack-source"
          end,
          authority_verifier: ->(**) { final_verification }, clock: -> { NOW }
        )
      end

      assert_raises(RuntimeError) { factory.call.call }
      assert_equal "applying", state.read.fetch("status")
      result = factory.call.call

      assert_equal "committed", result.fetch("status")
      assert_equal 1, materializations, "durable task binding must suppress rematerialization"
      assert_equal 2, acknowledgements
    end
  end

  private

  def manifest
    Hive::PatrolFix::Migration::DispositionManifest.build(
      inventory: inventory,
      reconciliation: {
        "groups" => [ group ], "dispositions" => [ disposition ],
        "observation_dispositions" => []
      }
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

  def inventory_with_second_source
    candidates = [ candidate, second_candidate ]
    {
      "count" => candidates.length,
      "root_digest" =>
        Hive::PatrolFix::Migration::DispositionManifest.inventory_root(candidates),
      "candidates" => candidates,
      "opaque_v3" => inventory.fetch("opaque_v3")
    }
  end

  def candidate
    {
      "source_kind" => "ordinary_finding", "source_id" => "finding-1",
      "source_schema" => "hive-patrol-finding/v1", "canonical_digest" => "e" * 64,
      "authority_state" => "accepted", "semantic_root" => "refresh",
      "observations" => [], "blocking_reason" => nil
    }
  end

  def second_candidate
    candidate.merge(
      "source_id" => "finding-2", "canonical_digest" => "a" * 64,
      "semantic_root" => "retry"
    )
  end

  def manifest_for_inventory(source_inventory)
    second_group = group.merge(
      "group_id" => "group-two",
      "candidate_set_digest" => Digest::SHA256.hexdigest(
        Hive::PatrolFix.canonical_json([
          [ "ordinary_finding:finding-2", second_candidate.fetch("canonical_digest") ]
        ])
      ),
      "members" => [ "ordinary_finding:finding-2" ],
      "canonical_source" => "ordinary_finding:finding-2"
    )
    second_disposition = disposition.merge(
      second_candidate.slice("source_id", "canonical_digest"),
      "group_id" => "group-two"
    )
    Hive::PatrolFix::Migration::DispositionManifest.build(
      inventory: source_inventory,
      reconciliation: {
        "groups" => [ group, second_group ],
        "dispositions" => [ disposition, second_disposition ],
        "observation_dispositions" => []
      }
    )
  end

  def group
    {
      "group_id" => "group-one", "candidate_set_digest" => Digest::SHA256.hexdigest(
        Hive::PatrolFix.canonical_json([
          [ "ordinary_finding:finding-1", candidate.fetch("canonical_digest") ]
        ])
      ),
      "members" => [ "ordinary_finding:finding-1" ],
      "canonical_source" => "ordinary_finding:finding-1",
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

  def epoch_port(events, expected_epoch: 7)
    Object.new.tap do |port|
      port.define_singleton_method(:snapshot) do
        { "ordinary_patrol" => expected_epoch,
          "architecture_patrol" => expected_epoch }
      end
      port.define_singleton_method(:ownership_snapshot) do
        {
          "ordinary_patrol" => { "owner" => "legacy", "admission" => true },
          "architecture_patrol" => { "owner" => "legacy", "admission" => true }
        }
      end
      port.define_singleton_method(:fence!) do |expected:, ownership:, inventory_guard:|
        raise "wrong ownership" unless ownership.values.all? { |mode| mode["admission"] }
        inventory_guard.call
        events << :fence_guard_inventory
        events << :fence
        raise "wrong epoch" unless expected.values == [ expected_epoch, expected_epoch ]
        { "ordinary_patrol" => expected_epoch + 1,
          "architecture_patrol" => expected_epoch + 1 }
      end
      port.define_singleton_method(:activate_discovery!) do |expected:, ownership:|
        events << :activate
        raise "wrong ownership" unless ownership.values.all? { |mode| mode["owner"] == "legacy" }
        expected
      end
    end
  end

  def final_verification
    {
      "inventory_count" => 1,
      "inventory_root_digest" => inventory.fetch("root_digest"),
      "disposition_count" => 1, "completed_group_count" => 1,
      "authority_digest" => "f" * 64
    }
  end
end
