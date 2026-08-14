require "test_helper"
require "json_schemer"
require "hive/patrol/feature"
require "hive/refactor_patrol/reporter"
require "hive/refactor_patrol/thesis"

class RefactorPatrolReporterTest < Minitest::Test
  def test_v4_routes_are_exhaustive_and_hive_forces_unsafe_findings_down
    accepted = thesis("accepted", route: "fix", confidence: "high", fingerprint: "fp-accepted")
    discussion = thesis("discussion", route: "discuss", fingerprint: "fp-discussion")
    below_threshold = thesis("below", confidence: "low", fingerprint: "fp-below")
    inadmissible = thesis(
      "inadmissible",
      admissible: false,
      admissibility_reason: "missing measurable signal",
      flags: [ "inadmissible" ],
      fingerprint: "fp-inadmissible"
    )
    suppressed = thesis("suppressed", fingerprint: "fp-suppressed")

    payload = reporter.v4_envelope(
      **v4_args(
        theses: [ accepted, discussion, below_threshold, inadmissible, suppressed ],
        suppressed: [ { "id" => "suppressed", "reason" => "collision_already_seen", "reference" => "legacy-fp" } ]
      )
    )

    all_ids = %w[fix discuss dismiss].flat_map { |key| payload.fetch(key).map { |item| item.fetch("id") } }
    assert_equal %w[accepted below discussion inadmissible suppressed], all_ids.sort
    assert_equal all_ids.uniq, all_ids
    assert_equal accepted.to_h, payload.fetch("fix").first.fetch("thesis")
    assert_equal "discuss", payload.fetch("discuss").first.fetch("route")

    dismissed = payload.fetch("dismiss").to_h { |item| [ item.fetch("id"), item ] }
    assert_equal true, dismissed.fetch("below").fetch("admissible")
    assert_equal [ "below_min_confidence" ], dismissed.fetch("below").fetch("reasons")
    assert_equal false, dismissed.fetch("inadmissible").fetch("admissible")
    assert_includes dismissed.fetch("inadmissible").fetch("reasons"), "inadmissible"
    assert_includes dismissed.fetch("inadmissible").fetch("reasons"), "missing measurable signal"
    assert v4_schemer.valid?(payload), v4_schemer.validate(payload).map { |error| error["error"] }.inspect
  end

  def test_v4_zero_reasons_distinguish_no_slice_no_theses_and_all_dismissed
    no_slice = reporter.v4_envelope(**v4_args(features: [], theses: []))
    no_theses = reporter.v4_envelope(**v4_args(features: [ feature ], theses: []))
    only = thesis("only", fingerprint: "fp-only")
    all_dismissed = reporter.v4_envelope(
      **v4_args(
        features: [ feature ],
        theses: [ only ],
        suppressed: [ { "id" => "only", "reason" => "collision_dismissed" } ]
      )
    )

    assert_equal "no_mapped_slice", no_slice.fetch("zero_reason")
    assert_equal "no_theses", no_theses.fetch("zero_reason")
    assert_equal "all_dismissed", all_dismissed.fetch("zero_reason")
    [ no_slice, no_theses, all_dismissed ].each do |payload|
      assert payload.fetch("complete")
      assert v4_schemer.valid?(payload), v4_schemer.validate(payload).map { |error| error["error"] }.inspect
    end
  end

  def test_v4_review_errors_force_partial_even_when_caller_reports_complete
    payload = reporter.v4_envelope(
      **v4_args(
        features: [ feature ],
        theses: [],
        complete: true,
        review_errors: [ { "feature_id" => "checkout", "error" => "agent_failed", "message" => "stopped" } ]
      )
    )

    assert_equal false, payload.fetch("complete")
    assert_nil payload.fetch("zero_reason")
    assert_equal "agent_failed", payload.fetch("review_errors").first.fetch("error")
    assert v4_schemer.valid?(payload), v4_schemer.validate(payload).map { |error| error["error"] }.inspect
  end

  def test_v4_actions_do_not_change_analysis_disposition
    item = thesis("accepted", confidence: "high", fingerprint: "fp-accepted")
    action = {
      "canonical_action_id" => "fix-fp-accepted",
      "thesis_id" => "accepted",
      "thesis_fingerprint" => "fp-accepted",
      "kind" => "fix",
      "owner_job_id" => "job-1",
      "outcome" => "validation_failed",
      "terminal" => true,
      "receipts" => { "validation" => { "ok" => false } }
    }

    payload = reporter.v4_envelope(**v4_args(theses: [ item ], actions: [ action ]))

    assert_equal [ "accepted" ], payload.fetch("fix").map { |entry| entry.fetch("id") }
    assert_empty payload.fetch("discuss")
    assert_equal "validation_failed", payload.fetch("actions").first.fetch("outcome")
    assert v4_schemer.valid?(payload), v4_schemer.validate(payload).map { |error| error["error"] }.inspect
  end

  def test_v4_retains_inadmissibility_details_on_dismissed_theses
    item = thesis(
      "partial", admissible: false,
      admissibility_reason: "evidence could not be verified",
      flags: [ "unverified_evidence" ]
    )

    payload = reporter.v4_envelope(**v4_args(theses: [ item ]))
    retained = payload.dig("dismiss", 0)

    assert_equal "dismiss", retained.fetch("route")
    assert_includes retained.fetch("reasons"), "unverified_evidence"
    assert_includes retained.fetch("reasons"), "evidence could not be verified"
    assert v4_schemer.valid?(payload), v4_schemer.validate(payload).map { |error| error["error"] }.inspect
  end

  def test_v4_rejects_duplicate_thesis_ids_instead_of_losing_a_disposition
    duplicate = thesis("same", fingerprint: "fp-one")

    error = assert_raises(ArgumentError) do
      reporter.v4_envelope(**v4_args(theses: [ duplicate, thesis("same", fingerprint: "fp-two") ]))
    end

    assert_includes error.message, "duplicate thesis id"
  end

  def test_local_v4_projects_scoreless_routes_without_ranked_compatibility_fields
    dismissed = thesis("z-dismissed", route: "dismiss")
    discuss = thesis("b-discuss", route: "discuss")
    fixed = thesis("a-fix", route: "fix")

    payload = reporter.envelope(
      project: "demo",
      project_root: "/tmp/demo",
      dry_run: true,
      features: [ feature ],
      theses: [ dismissed, discuss, fixed ],
      suppressed: [],
      last_scanned_sha: "abc"
    )

    assert_equal [ "a-fix" ], payload.fetch("fix").map { |item| item.fetch("id") }
    assert_equal [ "b-discuss" ], payload.fetch("discuss").map { |item| item.fetch("id") }
    assert_equal [ "z-dismissed" ], payload.fetch("dismiss").map { |item| item.fetch("id") }
    %w[fix discuss dismiss].flat_map { |route| payload.fetch(route) }.each do |item|
      refute item.key?("score")
    end
    refute payload.key?("ranked")
    assert payload.fetch("review_complete")
    assert_empty payload.fetch("review_errors")
  end

  def test_v4_review_errors_are_explicit_partial_results
    error = {
      "feature_id" => "checkout",
      "error" => "agent_failed",
      "message" => "token cap reached",
      "details" => {
        "resource_exhaustion" => { "reason" => "token_limit", "limit" => 100, "observed" => 105 }
      }
    }
    payload = reporter.envelope(
      project: "demo", project_root: "/tmp/demo", dry_run: true,
      features: [ feature ], theses: [], suppressed: [], last_scanned_sha: "abc",
      complete: false, review_errors: [ error ]
    )

    refute payload.fetch("review_complete")
    assert_equal [ error ], payload.fetch("review_errors")
    refute payload.fetch("feature_results").first.fetch("complete")
  end

  def test_error_envelope_rejects_unknown_schema_version
    assert_raises(ArgumentError) do
      Hive::RefactorPatrol::Reporter.error_envelope(
        RuntimeError.new("boom"), version: 99, error_kind: "internal"
      )
    end
  end

  def test_v4_rejects_duplicate_suppression_ids
    item = thesis("only")
    suppressions = [
      { "id" => "only", "reason" => "already_seen" },
      { "id" => "only", "reason" => "dismissed" }
    ]

    error = assert_raises(ArgumentError) do
      reporter.v4_envelope(**v4_args(theses: [ item ], suppressed: suppressions))
    end

    assert_includes error.message, "duplicate suppressed thesis id"
  end

  def test_v4_rejects_unsupported_and_inconsistent_zero_reasons
    unsupported = assert_raises(ArgumentError) do
      reporter.v4_envelope(**v4_args(features: [], zero_reason: "nothing_here"))
    end
    inconsistent = assert_raises(ArgumentError) do
      reporter.v4_envelope(**v4_args(features: [], zero_reason: "no_theses"))
    end

    assert_includes unsupported.message, "unsupported zero reason"
    assert_includes inconsistent.message, "does not match"
  end

  private

  def reporter
    @reporter ||= Hive::RefactorPatrol::Reporter.new(
      "refactor_patrol" => { "min_confidence" => "medium", "max_theses_per_run" => 10 }
    )
  end

  def v4_args(overrides = {})
    {
      job_id: "job-1",
      project: "demo",
      project_root: "/tmp/demo",
      dry_run: false,
      source_pr: {
        "url" => "https://github.com/acme/demo/pull/7",
        "number" => 7,
        "repository" => "acme/demo",
        "registration" => "demo",
        "base_branch" => "main",
        "base_sha" => "a" * 40,
        "merge_sha" => "b" * 40,
        "merged_at" => "2026-07-10T10:00:00Z",
        "changed_paths" => [ "lib/checkout.rb" ],
        "manifest_checksum" => "d" * 64
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

  def thesis(id, route: "fix", confidence: "medium", admissible: true, admissibility_reason: "ok", flags: [], fingerprint: "fp")
    Hive::RefactorPatrol::Thesis.new(
      id: id,
      feature_id: "checkout",
      feature: "Checkout",
      problem: "Checkout mixes concerns",
      cost: "Changes fan out",
      evidence: [
        {
          "file" => "lib/checkout.rb",
          "line" => 1,
          "snippet" => "class Checkout",
          "claim" => "checkout mixes concerns"
        }
      ],
      proposed_refactor: "Extract a service",
      feature_boundary: { "owned_files" => [ "lib/checkout.rb" ], "entrypoints" => [ "lib/checkout.rb" ] },
      architecture_effects: [ "isolate recurring edits behind one owner" ],
      route: route,
      confidence: confidence,
      risk: {
        "caps" => { "single_feature" => true },
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

  def v4_schemer
    @v4_schemer ||= JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol", version: 4))))
  end
end
