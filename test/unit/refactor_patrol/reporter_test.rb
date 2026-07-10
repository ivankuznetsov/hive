require "test_helper"
require "json_schemer"
require "hive/patrol/feature"
require "hive/refactor_patrol/reporter"
require "hive/refactor_patrol/thesis"

class RefactorPatrolReporterTest < Minitest::Test
  def test_v2_dispositions_are_exhaustive_and_below_threshold_is_flagged
    accepted = thesis("accepted", confidence: "high", fingerprint: "fp-accepted")
    below_threshold = thesis("below", confidence: "low", fingerprint: "fp-below")
    inadmissible = thesis(
      "inadmissible",
      admissible: false,
      admissibility_reason: "missing measurable signal",
      flags: [ "inadmissible" ],
      fingerprint: "fp-inadmissible"
    )
    suppressed = thesis("suppressed", fingerprint: "fp-suppressed")

    payload = reporter.v2_envelope(
      **v2_args(
        theses: [ accepted, below_threshold, inadmissible, suppressed ],
        suppressed: [ { "id" => "suppressed", "reason" => "collision_already_seen", "reference" => "legacy-fp" } ]
      )
    )

    all_ids = %w[accepted flagged suppressed].flat_map { |key| payload.fetch(key).map { |item| item.fetch("id") } }
    assert_equal %w[accepted below inadmissible suppressed], all_ids.sort
    assert_equal all_ids.uniq, all_ids

    flagged = payload.fetch("flagged").to_h { |item| [ item.fetch("id"), item ] }
    assert_equal true, flagged.fetch("below").fetch("admissible")
    assert_equal [ "below_min_confidence" ], flagged.fetch("below").fetch("reasons")
    assert_equal false, flagged.fetch("inadmissible").fetch("admissible")
    assert_includes flagged.fetch("inadmissible").fetch("reasons"), "inadmissible"
    assert_includes flagged.fetch("inadmissible").fetch("reasons"), "missing measurable signal"
    assert v2_schemer.valid?(payload), v2_schemer.validate(payload).map { |error| error["error"] }.inspect
  end

  def test_v2_zero_reasons_distinguish_no_slice_no_theses_and_all_suppressed
    no_slice = reporter.v2_envelope(**v2_args(features: [], theses: []))
    no_theses = reporter.v2_envelope(**v2_args(features: [ feature ], theses: []))
    only = thesis("only", fingerprint: "fp-only")
    all_suppressed = reporter.v2_envelope(
      **v2_args(
        features: [ feature ],
        theses: [ only ],
        suppressed: [ { "id" => "only", "reason" => "collision_dismissed" } ]
      )
    )

    assert_equal "no_mapped_slice", no_slice.fetch("zero_reason")
    assert_equal "no_theses", no_theses.fetch("zero_reason")
    assert_equal "all_suppressed", all_suppressed.fetch("zero_reason")
    [ no_slice, no_theses, all_suppressed ].each do |payload|
      assert payload.fetch("complete")
      assert v2_schemer.valid?(payload), v2_schemer.validate(payload).map { |error| error["error"] }.inspect
    end
  end

  def test_v2_review_errors_force_partial_even_when_caller_reports_complete
    payload = reporter.v2_envelope(
      **v2_args(
        features: [ feature ],
        theses: [],
        complete: true,
        review_errors: [ { "feature_id" => "checkout", "error" => "agent_failed", "message" => "stopped" } ]
      )
    )

    assert_equal false, payload.fetch("complete")
    assert_nil payload.fetch("zero_reason")
    assert_equal "agent_failed", payload.fetch("review_errors").first.fetch("error")
    assert v2_schemer.valid?(payload), v2_schemer.validate(payload).map { |error| error["error"] }.inspect
  end

  def test_v2_actions_do_not_change_analysis_disposition
    item = thesis("accepted", confidence: "high", fingerprint: "fp-accepted")
    action = {
      "canonical_action_id" => "fix-fp-accepted",
      "thesis_id" => "accepted",
      "kind" => "fix",
      "owner_job_id" => "job-1",
      "outcome" => "validation_failed",
      "terminal" => true,
      "receipts" => { "validation" => { "ok" => false } }
    }

    payload = reporter.v2_envelope(**v2_args(theses: [ item ], actions: [ action ]))

    assert_equal [ "accepted" ], payload.fetch("accepted").map { |entry| entry.fetch("id") }
    assert_empty payload.fetch("flagged")
    assert_equal "validation_failed", payload.fetch("actions").first.fetch("outcome")
    assert v2_schemer.valid?(payload), v2_schemer.validate(payload).map { |error| error["error"] }.inspect
  end

  def test_v2_rejects_duplicate_thesis_ids_instead_of_losing_a_disposition
    duplicate = thesis("same", fingerprint: "fp-one")

    error = assert_raises(ArgumentError) do
      reporter.v2_envelope(**v2_args(theses: [ duplicate, thesis("same", fingerprint: "fp-two") ]))
    end

    assert_includes error.message, "duplicate thesis id"
  end

  private

  def reporter
    @reporter ||= Hive::RefactorPatrol::Reporter.new(
      "refactor_patrol" => { "min_confidence" => "medium", "max_theses_per_run" => 10 }
    )
  end

  def v2_args(overrides = {})
    {
      job_id: "job-1",
      project: "demo",
      project_root: "/tmp/demo",
      dry_run: false,
      source_pr: {
        "url" => "https://github.com/acme/demo/pull/7",
        "number" => 7,
        "repository" => "acme/demo",
        "base_branch" => "main",
        "base_sha" => "a" * 40,
        "merge_sha" => "b" * 40
      },
      analysis_sha: "c" * 40,
      features: [ feature ],
      theses: [],
      suppressed: [],
      complete: true,
      review_errors: [],
      actions: [],
      attempts: []
    }.merge(overrides)
  end

  def feature
    Hive::Patrol::Feature.new(
      id: "checkout",
      kind: "command",
      entrypoints: [ "lib/checkout.rb" ],
      owned_files: [ "lib/checkout.rb" ],
      context_files: [],
      tests: [ "test/checkout_test.rb" ]
    )
  end

  def thesis(id, confidence: "medium", admissible: true, admissibility_reason: "ok", flags: [], fingerprint: "fp")
    Hive::RefactorPatrol::Thesis.new(
      id: id,
      feature_id: "checkout",
      feature: "Checkout",
      problem: "Checkout mixes concerns",
      cost: "Changes fan out",
      evidence: [ { "file" => "lib/checkout.rb", "signal" => "churn", "value" => 7 } ],
      proposed_refactor: "Extract a service",
      feature_boundary: { "owned_files" => [ "lib/checkout.rb" ], "entrypoints" => [ "lib/checkout.rb" ] },
      expected_leverage: { "score" => 0.8, "breakdown" => { "churn" => 0.8 } },
      confidence: confidence,
      risk: {
        "caps" => { "est_files" => 2, "est_diff_lines" => 80, "single_feature" => true },
        "public_api_impact" => false,
        "public_api_details" => [],
        "cross_feature_impact" => false,
        "cross_feature_details" => [],
        "flags" => flags,
        "advisories" => []
      },
      required_validation: { "commands" => [ "test" ], "characterization_first" => false, "notes" => "" },
      admissible: admissible,
      admissibility_reason: admissibility_reason,
      follow_up_approval_state: "pending",
      fingerprint: fingerprint
    )
  end

  def v2_schemer
    @v2_schemer ||= JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol", version: 2))))
  end
end
