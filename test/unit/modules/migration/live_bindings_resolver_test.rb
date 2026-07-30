require "test_helper"
require "hive/modules/migration/live_bindings_resolver"
require_relative "../../../support/patrol_evidence_scenario"

class ModulesMigrationLiveBindingsResolverTest < Minitest::Test
  include PatrolEvidenceScenario

  def test_persisted_bundle_has_no_live_authority_and_unwired_run_provider_blocks
    bundle = qualification_bundle(lane: "deterministic")
    assert_equal %w[receipt records], bundle.keys.sort

    resolver =
      Hive::Modules::Migration::LiveBindingsResolver.new(
        project_provider: -> { PROJECT_BINDING },
        module_selections: selection_snapshot,
        run_authority_provider: nil
      )
    result = resolver.resolve(
      receipt: bundle.fetch("receipt"),
      records: bundle.fetch("records")
    )
    verification =
      Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: bundle.fetch("receipt"),
        records: bundle.fetch("records"),
        current_bindings: result.bindings,
        binding_blockers: result.blockers
      )

    assert_equal(
      %w[live_run_authority_unresolved],
      result.blockers
    )
    refute verification.verified?
    result.blockers.each do |blocker|
      assert_includes verification.blockers, blocker
    end
  end

  def test_run_authority_is_queried_only_by_run_and_lane_at_resolve_time
    bundle = qualification_bundle(lane: "deterministic")
    authority = qualification_case(
      lane: "deterministic"
    ).fetch("authority")
    calls = []
    provider = lambda do |run_id:, lane:|
      calls << [ run_id, lane ]
      authority
    end
    resolver =
      Hive::Modules::Migration::LiveBindingsResolver.new(
        project_provider: -> { PROJECT_BINDING },
        module_selections: selection_snapshot,
        run_authority_provider: provider
      )

    2.times do
      assert verify_bundle(bundle, resolver).verified?
    end
    assert_equal(
      [
        [ "compressed-run-1", "deterministic" ],
        [ "compressed-run-1", "deterministic" ]
      ],
      calls
    )
  end

  def test_foreign_run_authority_response_cannot_self_agree_with_receipt
    bundle = qualification_bundle(lane: "deterministic")
    authority = Marshal.load(
      Marshal.dump(
        qualification_case(
          lane: "deterministic"
        ).fetch("authority")
      )
    )
    authority["run_id"] = "foreign-run"
    authority["lane"] = "installed"
    authority.fetch("candidate")["installed_digest"] = "9" * 64
    resolver =
      Hive::Modules::Migration::LiveBindingsResolver.new(
        project_provider: -> { PROJECT_BINDING },
        module_selections: selection_snapshot,
        run_authority_provider: ->(run_id:, lane:) {
          assert_equal "compressed-run-1", run_id
          assert_equal "deterministic", lane
          authority
        }
      )

    verification = verify_bundle(bundle, resolver)

    assert_includes verification.blockers, "run_binding_mismatch"
    assert_includes verification.blockers, "lane_binding_mismatch"
    refute verification.verified?
  end

  def test_live_project_and_independent_run_authority_mismatches_are_named
    bundle = qualification_bundle(lane: "deterministic")
    authority = qualification_case(
      lane: "deterministic"
    ).fetch("authority")
    authority_cases = {
      "candidate_binding_mismatch" => lambda do |document|
        document.fetch("candidate")["sha"] = "f" * 40
      end,
      "scenario_manifest_binding_mismatch" => lambda do |document|
        document["scenario_manifest_digest"] = "8" * 64
      end,
      "artifact_binding_mismatch" => lambda do |document|
        document.fetch("artifact_digests")["bounded_log"] =
          "8" * 64
      end,
      "decision_binding_mismatch" => lambda do |document|
        document.fetch("decision_expectations")
                .first["repository_sha"] = "f" * 40
      end,
      "scenario_matrix_mismatch" => lambda do |document|
        document.fetch("required_matrix").pop
      end,
      "legacy_effect_expectation_mismatch" => lambda do |document|
        document.fetch("expected_legacy_effect_keys").pop
      end
    }
    cases = {
      "project_binding_mismatch" =>
        qualification_live_resolver(
          project_provider: lambda do
            PROJECT_BINDING.merge("name" => "other")
          end
        )
    }
    authority_cases.each do |blocker, mutation|
      document = Marshal.load(Marshal.dump(authority))
      mutation.call(document)
      cases[blocker] = qualification_live_resolver(
        authority_documents: {
          [ "compressed-run-1", "deterministic" ] =>
            document
        }
      )
    end

    cases.each do |blocker, resolver|
      verification = verify_bundle(bundle, resolver)
      assert_includes(
        verification.blockers,
        blocker,
        "expected #{blocker}"
      )
      refute verification.verified?
    end
  end

  def test_missing_malformed_and_unsafe_run_authority_are_explicit_blockers
    bundle = qualification_bundle(lane: "deterministic")
    cases = [
      [ "live_run_authority_unresolved", nil ],
      [
        "live_run_authority_unresolved",
        ->(run_id:, lane:) { run_id && lane && nil }
      ],
      [
        "live_run_authority_malformed",
        ->(run_id:, lane:) {
          { "run_id" => run_id, "lane" => lane }
        }
      ],
      [
        "live_run_authority_unsafe",
        ->(run_id:, lane:) {
          raise "unsafe #{run_id}:#{lane}"
        }
      ]
    ]

    cases.each do |blocker, provider|
      resolver =
        Hive::Modules::Migration::LiveBindingsResolver.new(
          project_provider: -> { PROJECT_BINDING },
          module_selections: selection_snapshot,
          run_authority_provider: provider
        )
      result = resolver.resolve(
        receipt: bundle.fetch("receipt"),
        records: bundle.fetch("records")
      )
      verification =
        Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
          receipt: bundle.fetch("receipt"),
          records: bundle.fetch("records"),
          current_bindings: result.bindings,
          binding_blockers: result.blockers
        )

      assert_includes result.blockers, blocker
      refute verification.verified?
    end
  end

  def test_every_exact_active_selection_field_and_epoch_is_live_bound
    bundle = qualification_bundle(lane: "deterministic")
    mutations = {
      "selection_epoch" => 3,
      "version" => "0.2.0",
      "catalog_commit" => "f" * 40,
      "source_commit" => "e" * 40,
      "manifest_digest" => "9" * 64,
      "configuration_digest" => "8" * 64
    }

    mutations.each do |field, value|
      selections = Marshal.load(
        Marshal.dump(module_selection_bindings)
      )
      if field == "selection_epoch"
        selections.fetch("patrol")[field] = value
      else
        selections.fetch("patrol").fetch("active")[field] = value
      end
      verification = verify_bundle(
        bundle,
        qualification_live_resolver(
          module_selections: selections
        )
      )
      assert_includes(
        verification.blockers,
        "module_selection_binding_mismatch",
        "expected #{field} drift to be rejected"
      )
      refute verification.verified?
    end
  end

  private

  def verify_bundle(bundle, resolver)
    result = resolver.resolve(
      receipt: bundle.fetch("receipt"),
      records: bundle.fetch("records")
    )
    Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
      receipt: bundle.fetch("receipt"),
      records: bundle.fetch("records"),
      current_bindings: result.bindings,
      binding_blockers: result.blockers
    )
  end
end
