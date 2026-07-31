require "test_helper"
require "hive/modules/migration/live_bindings_resolver"
require_relative "../../../support/patrol_evidence_scenario"

class ModulesMigrationLiveBindingsResolverTest < Minitest::Test
  include PatrolEvidenceScenario

  def test_run_authority_is_queried_by_selected_run_and_lane
    bundle = qualification_bundle(lane: "deterministic")
    authority = qualification_case(
      lane: "deterministic"
    ).fetch("authority")
    calls = []
    provider = lambda do |run_id:, lane:|
      calls << [ run_id, lane ]
      provider_outcome(
        status: "resolved",
        bindings: authority
      )
    end
    resolver = resolver(provider: provider)

    2.times do
      assert verify_bundle(bundle, resolver).verified?
    end
    assert_equal(
      [
        [ RUN_ID, "deterministic" ],
        [ RUN_ID, "deterministic" ]
      ],
      calls
    )
  end

  def test_foreign_typed_authority_is_a_failed_resolution
    bundle = qualification_bundle(lane: "deterministic")
    authority = deep_copy(
      qualification_case(
        lane: "deterministic"
      ).fetch("authority")
    )
    authority["run_id"] = "patrol-#{"f" * 64}"
    resolver = resolver(
      provider: lambda do |run_id:, lane:|
        run_id && lane &&
          provider_outcome(
            status: "resolved",
            bindings: authority
          )
      end
    )

    resolution = resolve_bundle(bundle, resolver)

    assert_equal "failed", resolution.status
    assert_equal(
      [ "live_run_authority_malformed" ],
      resolution.issues
    )
    assert_nil resolution.bindings
  end

  def test_live_project_and_descriptor_authority_mismatches_are_named
    bundle = qualification_bundle(lane: "deterministic")
    authority = qualification_case(
      lane: "deterministic"
    ).fetch("authority")
    authority_cases = {
      "candidate_binding_mismatch" => lambda do |document|
        document.fetch("candidate")["commit_sha"] = "f" * 40
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
        document["required_matrix"] =
          document.fetch("required_matrix").drop(1)
      end,
      "fault_matrix_mismatch" => lambda do |document|
        document["required_faults"] =
          document.fetch("required_faults").drop(1)
      end,
      "legacy_effect_expectation_mismatch" => lambda do |document|
        document["expected_legacy_effect_keys"] =
          document.fetch(
            "expected_legacy_effect_keys"
          ).drop(1)
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
      document = deep_copy(authority)
      mutation.call(document)
      cases[blocker] = qualification_live_resolver(
        authority_documents: {
          [ RUN_ID, "deterministic" ] => document
        }
      )
    end

    cases.each do |blocker, candidate_resolver|
      verification = verify_bundle(
        bundle, candidate_resolver
      )
      assert_includes(
        verification.blockers,
        blocker,
        "expected #{blocker}"
      )
      refute verification.verified?
    end
  end

  def test_provider_failed_and_blocked_outcomes_are_preserved
    bundle = qualification_bundle(lane: "deterministic")
    {
      "failed" => "qualification_input_unsafe",
      "blocked" => "qualification_lane_missing"
    }.each do |status, issue|
      candidate_resolver = resolver(
        provider: lambda do |run_id:, lane:|
          run_id && lane &&
            provider_outcome(
              status: status,
              issues: [ issue ]
            )
        end
      )
      resolution = resolve_bundle(
        bundle, candidate_resolver
      )
      verification =
        Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
          receipt: bundle.fetch("receipt"),
          records: bundle.fetch("records"),
          resolution: resolution
        )

      assert_equal status, resolution.status
      assert_equal status, verification.status
      assert_includes verification.blockers, issue
    end
  end

  def test_blocked_provider_is_consulted_before_nil_receipt_or_records
    calls = []
    candidate_resolver = resolver(
      provider: lambda do |run_id:, lane:|
        calls << [ run_id, lane ]
        provider_outcome(
          status: "blocked",
          issues: [
            "qualification_lane_blocked:" \
            "live_lane_not_authorized"
          ]
        )
      end
    )

    resolution = candidate_resolver.resolve(
      run_id: RUN_ID,
      lane: "installed",
      receipt: nil,
      records: nil
    )

    assert_equal [ [ RUN_ID, "installed" ] ], calls
    assert_equal "blocked", resolution.status
    assert_equal(
      [
        "qualification_lane_blocked:" \
        "live_lane_not_authorized"
      ],
      resolution.issues
    )
    assert_nil resolution.bindings
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
      selections = deep_copy(module_selection_bindings)
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

  def resolver(provider:)
    Hive::Modules::Migration::LiveBindingsResolver.new(
      project_provider: -> { PROJECT_BINDING },
      module_selections: selection_snapshot,
      run_authority_provider: provider
    )
  end

  def provider_outcome(status:, bindings: nil, issues: [])
    Hive::Modules::Migration::
      QualificationRunAuthorityProvider::Outcome.new(
        status: status,
        bindings: bindings,
        issues: issues.freeze
      ).freeze
  end

  def resolve_bundle(bundle, candidate_resolver)
    candidate_resolver.resolve(
      run_id: RUN_ID,
      lane: bundle.dig("receipt", "lane"),
      receipt: bundle.fetch("receipt"),
      records: bundle.fetch("records")
    )
  end

  def verify_bundle(bundle, candidate_resolver)
    resolution = resolve_bundle(bundle, candidate_resolver)
    Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
      receipt: bundle.fetch("receipt"),
      records: bundle.fetch("records"),
      resolution: resolution
    )
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end
end
