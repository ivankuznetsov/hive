require "test_helper"
require "hive/refactor_patrol/caps"
require "hive/refactor_patrol/thesis"

class RefactorPatrolCapsTest < Minitest::Test
  def test_exceeds_max_files_is_flagged_not_blocked
    thesis = sample_thesis(risk_hash: default_risk(est_files: 12))

    result = Hive::RefactorPatrol::Caps.new(cfg("max_files" => 8)).apply(thesis)

    refute result.blocked
    assert_includes thesis.risk.fetch("flags"), "exceeds_max_files"
  end

  def test_in_budget_diff_lines_are_not_flagged
    thesis = sample_thesis(risk_hash: default_risk(est_diff_lines: 300))

    Hive::RefactorPatrol::Caps.new(cfg("max_diff_lines" => 400)).apply(thesis)

    refute_includes thesis.risk.fetch("flags"), "exceeds_max_diff_lines"
  end

  def test_non_single_feature_is_flagged_when_cap_requires_single_feature
    thesis = sample_thesis(risk_hash: default_risk.merge("caps" => default_risk.fetch("caps").merge("single_feature" => false)))

    result = Hive::RefactorPatrol::Caps.new(cfg("single_feature_only" => true)).apply(thesis)

    refute result.blocked
    assert_includes thesis.risk.fetch("flags"), "not_single_feature"
  end

  # A thesis is behavior-preserving by contract: working inside files that
  # host public surface is an advisory, not an API change, so it must not
  # disqualify the thesis (no flag, public_api_impact stays false).
  def test_public_surface_paths_are_advisory_not_flagged
    cli = sample_thesis(boundary_files: [ "lib/hive/cli.rb" ])
    schema = sample_thesis(boundary_files: [ "schemas/foo.v1.json" ])

    Hive::RefactorPatrol::Caps.new(cfg).apply(cli)
    Hive::RefactorPatrol::Caps.new(cfg).apply(schema)

    [ cli, schema ].each do |thesis|
      assert_equal false, thesis.risk.fetch("public_api_impact")
      refute_includes thesis.risk.fetch("flags"), "public_api_impact"
      assert_includes thesis.risk.fetch("advisories"), "touches_public_api_surface"
    end
    assert_includes cli.risk.fetch("public_api_details"), "lib/hive/cli.rb"
    assert_includes schema.risk.fetch("public_api_details"), "schemas/foo.v1.json"
  end

  def test_agent_declared_public_api_impact_is_flagged
    thesis = sample_thesis(risk_hash: default_risk.merge("public_api_impact" => true))

    Hive::RefactorPatrol::Caps.new(cfg).apply(thesis)

    assert_includes thesis.risk.fetch("flags"), "public_api_impact"
    assert_empty thesis.risk.fetch("advisories")
  end

  def test_allowed_public_api_changes_produce_no_flag_or_advisory
    thesis = sample_thesis(boundary_files: [ "lib/hive/cli.rb" ])

    Hive::RefactorPatrol::Caps.new(cfg("allow_public_api_changes" => true)).apply(thesis)

    assert_empty thesis.risk.fetch("flags")
    assert_empty thesis.risk.fetch("advisories")
  end

  def test_out_of_boundary_evidence_marks_cross_feature_impact
    thesis = sample_thesis(evidence: [ { "file" => "lib/other.rb", "signal" => "fan_in", "value" => 2 } ])

    Hive::RefactorPatrol::Caps.new(cfg).apply(thesis)

    assert_equal true, thesis.risk.fetch("cross_feature_impact")
    assert_includes thesis.risk.fetch("cross_feature_details"), "lib/other.rb"
    assert_includes thesis.risk.fetch("flags"), "cross_feature_impact"
  end

  def test_dependency_manifest_is_flagged
    thesis = sample_thesis(boundary_files: [ "Gemfile" ])

    Hive::RefactorPatrol::Caps.new(cfg).apply(thesis)

    assert_includes thesis.risk.fetch("flags"), "dependency_bump"
    assert_equal true, thesis.risk.fetch("cross_feature_impact")
    assert_includes thesis.risk.fetch("cross_feature_details"), "Gemfile"
  end

  def test_in_bounds_thesis_has_no_flags
    thesis = sample_thesis

    Hive::RefactorPatrol::Caps.new(cfg).apply(thesis)

    assert_empty thesis.risk.fetch("flags")
    assert_empty thesis.risk.fetch("advisories")
    assert_equal false, thesis.risk.fetch("public_api_impact")
    assert_equal false, thesis.risk.fetch("cross_feature_impact")
  end

  private

  def cfg(overrides = {})
    {
      "refactor_patrol" => {
        "caps" => {
          "single_feature_only" => true,
          "allow_dependency_bumps" => false,
          "allow_public_api_changes" => false,
          "max_files" => 8,
          "max_diff_lines" => 400,
          "allow_cross_feature" => false
        }.merge(overrides)
      }
    }
  end

  def sample_thesis(boundary_files: [ "lib/checkout.rb" ], evidence: nil, risk_hash: nil)
    Hive::RefactorPatrol::Thesis.new(
      id: "t1",
      feature_id: "checkout",
      feature: "Checkout",
      problem: "Checkout mixes concerns",
      cost: "Churn is high",
      evidence: evidence || [ { "file" => boundary_files.first, "signal" => "churn", "value" => 7 } ],
      proposed_refactor: "Extract service",
      feature_boundary: { "owned_files" => boundary_files, "entrypoints" => boundary_files },
      expected_leverage: { "score" => 0.5, "breakdown" => { "churn" => 0.5 } },
      confidence: "medium",
      risk: risk_hash || default_risk,
      required_validation: { "commands" => [ "test" ], "characterization_first" => false, "notes" => "" },
      admissible: true,
      admissibility_reason: "ok",
      follow_up_approval_state: "pending",
      fingerprint: "fp"
    )
  end

  def default_risk(est_files: 2, est_diff_lines: 80)
    {
      "caps" => { "est_files" => est_files, "est_diff_lines" => est_diff_lines, "single_feature" => true },
      "public_api_impact" => false,
      "public_api_details" => [],
      "cross_feature_impact" => false,
      "cross_feature_details" => [],
      "flags" => []
    }
  end
end
