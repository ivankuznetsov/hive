require "test_helper"
require "hive/modules/migration/live_bindings_resolver"
require "hive/modules/migration/qualification_run_authority_provider"
require "hive/modules/migration/report"
require_relative "../../../support/patrol_evidence_scenario"

class ModulesMigrationTypedQualificationResolutionTest <
    Minitest::Test
  include PatrolEvidenceScenario

  SELECTED_RUN_ID = "patrol-#{"7" * 64}".freeze

  def test_selected_run_and_lane_are_independent_of_receipt_claims
    bundle = qualification_bundle(lane: "deterministic")
    authority = deep_copy(
      qualification_case(
        lane: "deterministic"
      ).fetch("authority")
    )
    authority["run_id"] = SELECTED_RUN_ID
    calls = []
    resolver = resolver_with do |run_id:, lane:|
      calls << [ run_id, lane ]
      provider_outcome(
        status: "resolved", bindings: authority
      )
    end

    resolution = resolver.resolve(
      run_id: SELECTED_RUN_ID,
      lane: "deterministic",
      receipt: bundle.fetch("receipt"),
      records: bundle.fetch("records")
    )
    verification =
      Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: bundle.fetch("receipt"),
        records: bundle.fetch("records"),
        resolution: resolution
      )

    assert_equal(
      [ [ SELECTED_RUN_ID, "deterministic" ] ],
      calls
    )
    assert_equal "evidence_required", verification.status
    assert_includes verification.blockers, "run_binding_mismatch"
  end

  def test_provider_must_return_a_typed_outcome_and_cannot_be_nil
    assert_raises(Hive::ConfigError) do
      resolver_with_provider(nil)
    end

    bundle = qualification_bundle(lane: "deterministic")
    resolver = resolver_with do |run_id:, lane:|
      {
        "run_id" => run_id,
        "lane" => lane
      }
    end
    resolution = resolver.resolve(
      run_id: bundle.dig("receipt", "run_id"),
      lane: "deterministic",
      receipt: bundle.fetch("receipt"),
      records: bundle.fetch("records")
    )

    assert_equal "failed", resolution.status
    assert_equal(
      [ "live_run_authority_untyped" ],
      resolution.issues
    )
    assert_nil resolution.bindings
  end

  def test_failed_and_blocked_provider_outcomes_remain_typed
    bundle = qualification_bundle(lane: "deterministic")
    {
      "failed" => "qualification_result_timeout",
      "blocked" => "credential_missing:OPENROUTER_API_KEY"
    }.each do |status, issue|
      resolver = resolver_with do |run_id:, lane:|
        run_id && lane &&
          provider_outcome(status: status, issues: [ issue ])
      end
      resolution = resolver.resolve(
        run_id: bundle.dig("receipt", "run_id"),
        lane: "deterministic",
        receipt: bundle.fetch("receipt"),
        records: bundle.fetch("records")
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

  def test_required_faults_are_descriptor_bound
    bundle = qualification_bundle(lane: "deterministic")
    authority = deep_copy(
      qualification_case(
        lane: "deterministic"
      ).fetch("authority")
    )
    authority.fetch("required_faults").pop
    resolver = resolver_with do |run_id:, lane:|
      run_id && lane &&
        provider_outcome(
          status: "resolved", bindings: authority
        )
    end
    resolution = resolver.resolve(
      run_id: bundle.dig("receipt", "run_id"),
      lane: "deterministic",
      receipt: bundle.fetch("receipt"),
      records: bundle.fetch("records")
    )
    verification =
      Hive::Modules::Migration::PatrolEvidenceVerifier.verify(
        receipt: bundle.fetch("receipt"),
        records: bundle.fetch("records"),
        resolution: resolution
      )

    assert_equal "evidence_required", verification.status
    assert_includes verification.blockers, "fault_matrix_mismatch"
  end

  def test_typed_provider_cannot_bypass_lane_policy_validation
    bundle = qualification_bundle(lane: "deterministic")
    authority = deep_copy(
      qualification_case(
        lane: "deterministic"
      ).fetch("authority")
    )
    authority.fetch("lane_policy")["network"] = true
    resolver = resolver_with do |run_id:, lane:|
      run_id && lane &&
        provider_outcome(
          status: "resolved", bindings: authority
        )
    end

    resolution = resolver.resolve(
      run_id: bundle.dig("receipt", "run_id"),
      lane: "deterministic",
      receipt: bundle.fetch("receipt"),
      records: bundle.fetch("records")
    )

    assert_equal "failed", resolution.status
    assert_equal(
      [ "live_run_authority_malformed" ],
      resolution.issues
    )
    assert_nil resolution.bindings
  end

  def test_report_status_precedence_is_lane_order_independent
    failed = qualification_bundle(
      lane: "deterministic",
      lane_result: "failed",
      failure_reason: "command_nonzero"
    )
    blocked = qualification_bundle(
      lane: "installed",
      lane_result: "blocked",
      failure_reason: "credentials_missing"
    )
    orders = [
      {
        "deterministic" => failed,
        "installed" => blocked
      },
      {
        "installed" => blocked,
        "deterministic" => failed
      }
    ]

    reports = orders.map do |lane_evidence|
      Hive::Modules::Migration::Report.build(
        run_id: lane_evidence.dig(
          "deterministic", "receipt", "run_id"
        ),
        lane_evidence: lane_evidence,
        reviewer: "operator",
        reviewed_at: START + 40,
        live_bindings_resolver:
          qualification_live_resolver
      )
    end

    assert_equal %w[failed failed], reports.map(&:status)
    assert_equal(
      reports.first.payload,
      reports.last.payload
    )
  end

  def test_missing_lane_is_blocked_at_lane_and_report_level
    bundle = qualification_bundle(lane: "deterministic")
    report = Hive::Modules::Migration::Report.build(
      run_id: bundle.dig("receipt", "run_id"),
      lane_evidence: { "deterministic" => bundle },
      reviewer: "operator",
      reviewed_at: START + 40,
      live_bindings_resolver:
        qualification_live_resolver
    )

    assert_equal "blocked", report.status
    assert_equal(
      "blocked",
      report.payload.dig("lanes", "installed", "status")
    )
    assert_includes(
      report.blockers,
      "installed:lane_evidence_missing"
    )
    refute report.qualification.ready_for_operator?
  end

  def test_report_preserves_result_only_live_authorization_blocker
    deterministic =
      qualification_bundle(lane: "deterministic")
    authority = qualification_case(
      lane: "deterministic"
    ).fetch("authority")
    calls = []
    resolver = resolver_with do |run_id:, lane:|
      calls << [ run_id, lane ]
      if lane == "deterministic"
        provider_outcome(
          status: "resolved", bindings: authority
        )
      else
        provider_outcome(
          status: "blocked",
          issues: [
            "qualification_lane_blocked:" \
            "live_lane_not_authorized"
          ]
        )
      end
    end

    report = Hive::Modules::Migration::Report.build(
      run_id: RUN_ID,
      lane_evidence: {
        "deterministic" => deterministic
      },
      reviewer: "operator",
      reviewed_at: START + 40,
      live_bindings_resolver: resolver
    )

    assert_equal(
      [
        [ RUN_ID, "deterministic" ],
        [ RUN_ID, "installed" ]
      ],
      calls
    )
    assert_equal "blocked", report.status
    assert_equal(
      [ "qualification_lane_blocked:live_lane_not_authorized" ],
      report.payload.dig("lanes", "installed", "blockers")
    )
    %w[
      receipt_id effect_index_digest bundle_path bundle_digest
    ].each do |field|
      assert_nil report.payload.dig("lanes", "installed", field)
    end
    refute report.qualification.ready_for_operator?
  end

  private

  def resolver_with(&provider)
    resolver_with_provider(provider)
  end

  def resolver_with_provider(provider)
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

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end
end
