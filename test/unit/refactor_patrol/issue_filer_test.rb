require "test_helper"
require "hive/config"
require "hive/refactor_patrol/issue_filer"
require "hive/refactor_patrol/thesis"

class RefactorPatrolIssueFilerTest < Minitest::Test
  class FakeGh
    attr_accessor :issues, :create_error, :runtime_error
    attr_reader :lookups, :creates

    def initialize
      @issues = []
      @lookups = []
      @creates = []
    end

    def issues_with_marker(repository:, marker:, host:, cfg:)
      @lookups << [ repository, marker, host ]
      @issues
    end

    def create_issue(repository:, title:, body:, host:, cfg:)
      @creates << { repository: repository, title: title, body: body, host: host }
      raise RuntimeError, @runtime_error if @runtime_error
      raise Hive::GhError, @create_error if @create_error

      "https://#{host}/#{repository}/issues/9"
    end
  end

  def test_strategic_thesis_persists_intent_then_creates_one_bounded_issue
    gh = FakeGh.new
    intents = 0

    result = filer(gh).publish(
      thesis: thesis(flags: [ "exceeds_max_files" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: -> { intents += 1; true }
    )

    assert_equal "issue_created", result.outcome
    assert result.terminal
    assert_equal 1, intents
    assert_equal 1, gh.creates.size
    created = gh.creates.first
    assert_equal "acme/demo", created.fetch(:repository)
    assert_equal "github.com", created.fetch(:host)
    assert_includes created.fetch(:body), "Source PR: https://github.com/acme/demo/pull/7"
    assert_includes created.fetch(:body), "Problem evidence"
    assert_includes created.fetch(:body), "Expected leverage score: 0.4"
    assert_includes created.fetch(:body), "isolate repeated edits"
    assert_includes created.fetch(:body), marker
  end

  def test_open_and_closed_matching_issues_reconcile_without_create
    [
      [ "OPEN", "issue_linked_open" ],
      [ "CLOSED", "issue_closed_suppressed" ]
    ].each do |state, expected|
      gh = FakeGh.new
      gh.issues = [ { "number" => 4, "state" => state, "url" => "https://github.com/acme/demo/issues/4" } ]

      result = filer(gh).publish(
        thesis: thesis(flags: [ "cross_feature_impact" ]), family_id: family_id,
        canonical_action_id: action_id, job_id: "job-7", source: source,
        record_intent: successful_intent
      )

      assert_equal expected, result.outcome
      assert result.terminal
      assert_empty gh.creates
    end
  end

  def test_prior_creation_intent_never_blindly_retries_create
    gh = FakeGh.new

    result = filer(gh).publish(
      thesis: thesis(flags: [ "dependency_bump" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      creation_attempted: true,
      record_intent: successful_intent
    )

    assert_equal "remote_outcome_unknown", result.outcome
    refute result.terminal
    assert_empty gh.creates
  end

  def test_prior_intent_reconciles_after_current_issue_authority_is_revoked
    gh = FakeGh.new
    gh.issues = [
      {
        "number" => 4, "state" => "OPEN",
        "url" => "https://github.com/acme/demo/issues/4"
      }
    ]

    result = filer(gh, enabled: false).publish(
      thesis: thesis(flags: [ "dependency_bump" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      creation_attempted: true, record_intent: successful_intent
    )

    assert_equal "issue_linked_open", result.outcome
    assert result.terminal
    assert_equal [ [ "acme/demo", marker, "github.com" ] ], gh.lookups
    assert_empty gh.creates
  end

  def test_malformed_or_wrong_repository_reconciliation_fails_closed
    gh = FakeGh.new
    gh.issues = [
      { "number" => 4, "state" => "OPEN", "url" => "https://github.com/other/demo/issues/4" }
    ]

    result = filer(gh).publish(
      thesis: thesis(flags: [ "cross_feature_impact" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: successful_intent
    )

    assert_equal "issue_reconcile_failed", result.outcome
    refute result.terminal
    assert_empty gh.creates
  end

  def test_github_enterprise_host_is_authoritative_for_lookup_and_create
    gh = FakeGh.new
    enterprise_source = {
      "url" => "https://github.corp.example/acme/demo/pull/7",
      "repository" => "acme/demo"
    }

    result = filer(gh).publish(
      thesis: thesis(flags: [ "exceeds_max_files" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: enterprise_source,
      record_intent: successful_intent
    )

    assert_equal "issue_created", result.outcome
    assert_equal [ [ "acme/demo", marker, "github.corp.example" ] ], gh.lookups
    assert_equal "github.corp.example", gh.creates.first.fetch(:host)
    assert_equal "https://github.corp.example/acme/demo/issues/9", result.issue_url
  end

  def test_matching_repository_issue_on_wrong_host_fails_reconciliation
    gh = FakeGh.new
    gh.issues = [
      { "number" => 4, "state" => "OPEN", "url" => "https://evil.example/acme/demo/issues/4" }
    ]

    result = filer(gh).publish(
      thesis: thesis(flags: [ "cross_feature_impact" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: successful_intent
    )

    assert_equal "issue_reconcile_failed", result.outcome
    refute result.terminal
    assert_empty gh.creates
  end

  def test_create_failure_after_intent_is_remote_unknown
    gh = FakeGh.new
    gh.create_error = "lost response"
    intents = 0

    result = filer(gh).publish(
      thesis: thesis(flags: [ "not_single_feature" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: -> { intents += 1; true }
    )

    assert_equal 1, intents
    assert_equal "remote_outcome_unknown", result.outcome
    refute result.terminal
  end

  def test_non_gateway_exception_after_intent_is_also_remote_unknown
    gh = FakeGh.new
    gh.runtime_error = "connection parser crashed"

    result = filer(gh).publish(
      thesis: thesis(flags: [ "not_single_feature" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: successful_intent
    )

    assert_equal "remote_outcome_unknown", result.outcome
    refute result.terminal
    assert_includes result.receipts.fetch("error"), "connection parser crashed"
  end

  def test_low_confidence_inadmissible_and_non_strategic_theses_are_report_only
    cases = [
      thesis(flags: [ "exceeds_max_files" ], confidence: "low"),
      thesis(flags: [ "exceeds_max_files" ], admissible: false),
      thesis(flags: [ "exceeds_max_files" ], score: 0.1),
      thesis(flags: [ "missing_docs_validation" ]),
      thesis(flags: [ "collision_patrol_pr" ])
    ]

    cases.each do |item|
      gh = FakeGh.new
      result = filer(gh).publish(
        thesis: item, family_id: family_id, canonical_action_id: action_id,
        job_id: "job-7", source: source,
        record_intent: successful_intent
      )

      assert_equal "quality_gate_failed", result.outcome
      assert result.terminal
      assert_empty gh.lookups
      assert_empty gh.creates
    end
  end

  def test_issue_disabled_and_secret_content_make_no_remote_call
    disabled_gh = FakeGh.new
    disabled = filer(disabled_gh, enabled: false).publish(
      thesis: thesis(flags: [ "exceeds_max_files" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: successful_intent
    )
    assert_equal "issue_disabled", disabled.outcome
    assert_empty disabled_gh.lookups

    secret_gh = FakeGh.new
    item = thesis(flags: [ "exceeds_max_files" ])
    item.problem = "credential sk-#{'a' * 48}"
    secret = filer(secret_gh).publish(
      thesis: item, family_id: family_id, canonical_action_id: action_id,
      job_id: "job-7", source: source,
      record_intent: successful_intent
    )
    assert_equal "secret_detected", secret.outcome
    assert_empty secret_gh.creates
  end

  def test_issue_creation_requires_an_affirmative_durable_intent_receipt
    gh = FakeGh.new

    result = filer(gh).publish(
      thesis: thesis(flags: [ "exceeds_max_files" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: -> { nil }
    )

    assert_equal "intent_persist_failed", result.outcome
    refute result.terminal
    assert_empty gh.creates
  end

  def test_family_and_canonical_action_identity_must_be_durable_ids
    gh = FakeGh.new
    item = thesis(flags: [ "exceeds_max_files" ])

    invalid_family = filer(gh).publish(
      thesis: item, family_id: "family", canonical_action_id: action_id,
      job_id: "job-7", source: source, record_intent: successful_intent
    )
    invalid_action = filer(gh).publish(
      thesis: item, family_id: family_id, canonical_action_id: "issue:#{family_id}",
      job_id: "job-7", source: source, record_intent: successful_intent
    )

    assert_equal "invalid_family", invalid_family.outcome
    assert_equal "invalid_action", invalid_action.outcome
    assert_empty gh.lookups
    assert_empty gh.creates
  end

  private

  def filer(gh, enabled: true)
    cfg = Hive::Config.deep_dup(Hive::Config::DEFAULTS)
    cfg["refactor_patrol"]["issue_filing"]["enabled"] = enabled
    Hive::RefactorPatrol::IssueFiler.new(Dir.pwd, cfg: cfg, gh: gh)
  end

  def thesis(flags:, confidence: "medium", admissible: true, score: 0.4)
    Hive::RefactorPatrol::Thesis.new(
      id: "extract", feature_id: "architecture-services-checkout", feature: "Checkout",
      problem: "Checkout mixes validation and payment policy",
      cost: "Changes fan out across responsibilities",
      evidence: [
        {
          "file" => "services/checkout/core.ts", "line" => 42,
          "snippet" => "validateAndCharge()", "claim" => "Problem evidence"
        }
      ],
      proposed_refactor: "Extract a payment-policy boundary",
      feature_boundary: { "owned_files" => [ "services/checkout/core.ts" ], "entrypoints" => [] },
      expected_leverage: {
        "score" => score, "breakdown" => { "coupling" => score },
        "drivers" => [
          { "signal" => "coupling", "relief" => 0.5, "mechanism" => "isolate repeated edits" }
        ]
      },
      confidence: confidence,
      risk: {
        "flags" => flags, "caps" => { "est_files" => 9, "est_diff_lines" => 200 },
        "public_api_impact" => false, "public_api_details" => [],
        "cross_feature_impact" => false, "cross_feature_details" => []
      },
      required_validation: {
        "commands" => [ "test" ], "characterization_first" => false,
        "notes" => "Run the checkout tests"
      },
      admissible: admissible, admissibility_reason: admissible ? "anchored" : "missing anchor",
      follow_up_approval_state: "pending", fingerprint: "fp-1"
    )
  end

  def source
    {
      "url" => "https://github.com/acme/demo/pull/7",
      "repository" => "acme/demo"
    }
  end

  def family_id = "af1-#{'a' * 64}"
  def action_id = "issue-#{'b' * 64}"
  def marker = "<!-- hive-refactor-patrol family=#{family_id} action=#{action_id} -->"
  def successful_intent = -> { true }
end
