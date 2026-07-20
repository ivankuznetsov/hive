require "test_helper"
require "hive/config"
require "hive/refactor_patrol/issue_filer"
require "hive/refactor_patrol/thesis"

class RefactorPatrolIssueFilerTest < Minitest::Test
  class FakeGh
    attr_accessor :issues, :create_error, :runtime_error, :lookup_error
    attr_reader :lookups, :creates

    def initialize
      @issues = []
      @lookups = []
      @creates = []
    end

    def issues_for_repository(repository:, host:, cfg:)
      @lookups << [ repository, host ]
      raise Hive::GhError, @lookup_error if @lookup_error

      @issues.map do |issue|
        { "title" => "Architecture patrol finding", "body" => nil }.merge(issue)
      end
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
      thesis: thesis(flags: [ "public_api_impact" ]), family_id: family_id,
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
    assert_includes created.fetch(:body), "Follow-up approval: pending"
    assert_includes created.fetch(:body), marker
  end

  def test_open_and_closed_matching_issues_reconcile_without_create
    [
      [ "OPEN", "issue_linked_open" ],
      [ "CLOSED", "issue_closed_suppressed" ]
    ].each do |state, expected|
      gh = FakeGh.new
      gh.issues = [
        {
          "number" => 4, "state" => state,
          "url" => "https://github.com/acme/demo/issues/4", "body" => marker
        }
      ]

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

  def test_issue_body_does_not_trust_the_model_authored_approval_state
    gh = FakeGh.new

    result = filer(gh).publish(
      thesis: thesis(flags: [ "public_api_impact" ], follow_up_approval_state: "approved"),
      family_id: family_id, canonical_action_id: action_id,
      job_id: "job-7", source: source, record_intent: successful_intent
    )

    assert_equal "issue_created", result.outcome
    assert_includes gh.creates.first.fetch(:body), "Follow-up approval: pending"
    refute_includes gh.creates.first.fetch(:body), "Follow-up approval: approved"
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

  def test_structured_creation_intent_is_validated_and_reconciled
    gh = FakeGh.new
    gh.issues = [
      {
        "number" => 4, "state" => "OPEN",
        "url" => "https://github.com/acme/demo/issues/4", "body" => marker
      }
    ]
    publication_state = {
      "issue_create_intent" => Hive::RefactorPatrol::IssueFiler.create_intent_payload(
        canonical_action_id: action_id, repository: "acme/demo",
        family_id: family_id, thesis_fingerprint: "fp-1"
      )
    }

    result = filer(gh).publish(
      thesis: thesis(flags: [ "dependency_bump" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      publication_state: publication_state, record_intent: successful_intent
    )

    assert_equal "issue_linked_open", result.outcome
    assert_empty gh.creates
  end

  def test_structured_intent_with_incomplete_source_is_invalid_publication_state
    gh = FakeGh.new
    state = {
      "issue_create_intent" => Hive::RefactorPatrol::IssueFiler.create_intent_payload(
        canonical_action_id: action_id, repository: "acme/demo",
        family_id: family_id, thesis_fingerprint: "fp-1"
      )
    }

    result = filer(gh).publish(
      thesis: thesis(flags: [ "dependency_bump" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7",
      source: source.reject { |key, _value| key == "repository" },
      publication_state: state, record_intent: successful_intent
    )

    assert_equal "invalid_publication_state", result.outcome
    assert_empty gh.lookups
  end

  def test_prior_intent_reconciles_after_current_issue_authority_is_revoked
    gh = FakeGh.new
    gh.issues = [
      {
        "number" => 4, "state" => "OPEN",
        "url" => "https://github.com/acme/demo/issues/4", "body" => marker
      }
    ]

    result = filer(gh, enabled: false).publish(
      thesis: thesis(flags: [ "dependency_bump" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      creation_attempted: true, record_intent: successful_intent
    )

    assert_equal "issue_linked_open", result.outcome
    assert result.terminal
    assert_equal [ [ "acme/demo", "github.com" ] ], gh.lookups
    assert_empty gh.creates
  end

  def test_malformed_or_wrong_repository_reconciliation_fails_closed
    gh = FakeGh.new
    gh.issues = [
      {
        "number" => 4, "state" => "OPEN", "url" => "https://github.com/other/demo/issues/4",
        "body" => marker
      }
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

  def test_invalid_issue_input_is_terminal_and_never_reaches_github
    gh = FakeGh.new
    missing_repository = source.reject { |key, _value| key == "repository" }
    invalid_url = source.merge("url" => "http://[")

    [ missing_repository, invalid_url ].each do |invalid_source|
      result = filer(gh).publish(
        thesis: thesis(flags: [ "cross_feature_impact" ]), family_id: family_id,
        canonical_action_id: action_id, job_id: "job-7", source: invalid_source,
        record_intent: successful_intent
      )

      assert_equal "invalid_issue_input", result.outcome
      assert result.terminal
    end
    assert_empty gh.lookups
    assert_empty gh.creates
  end

  def test_malformed_issue_url_fails_reconciliation_without_creation
    gh = FakeGh.new
    gh.issues = [
      { "number" => 4, "state" => "OPEN", "url" => "http://[", "body" => marker }
    ]

    result = filer(gh).publish(
      thesis: thesis(flags: [ "cross_feature_impact" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: successful_intent
    )

    assert_equal "issue_reconcile_failed", result.outcome
    assert_empty gh.creates
  end

  def test_github_enterprise_host_is_authoritative_for_lookup_and_create
    gh = FakeGh.new
    enterprise_source = {
      "url" => "https://github.corp.example/acme/demo/pull/7",
      "repository" => "acme/demo"
    }

    result = filer(gh).publish(
      thesis: thesis(flags: [ "public_api_impact" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: enterprise_source,
      record_intent: successful_intent
    )

    assert_equal "issue_created", result.outcome
    assert_equal [ [ "acme/demo", "github.corp.example" ] ], gh.lookups
    assert_equal "github.corp.example", gh.creates.first.fetch(:host)
    assert_equal "https://github.corp.example/acme/demo/issues/9", result.issue_url
  end

  def test_matching_repository_issue_on_wrong_host_fails_reconciliation
    gh = FakeGh.new
    gh.issues = [
      {
        "number" => 4, "state" => "OPEN", "url" => "https://evil.example/acme/demo/issues/4",
        "body" => marker
      }
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

  def test_legacy_dry_run_issues_672_692_and_708_reconcile_as_one_semantic_family
    gh = FakeGh.new
    gh.issues = [ 708, 672, 692 ].map { |number| legacy_dry_run_issue(number) }

    result = filer(gh).publish(
      thesis: dry_run_thesis, family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: successful_intent
    )

    assert_equal "issue_linked_open", result.outcome
    assert result.terminal
    assert_equal "https://github.com/acme/demo/issues/672", result.issue_url
    assert_equal "legacy_semantic", result.receipts.fetch("match_kind")
    assert_equal %w[
      https://github.com/acme/demo/issues/692
      https://github.com/acme/demo/issues/708
    ], result.receipts.fetch("duplicate_issue_urls")
    assert_empty gh.creates
  end

  def test_legacy_wrapper_issues_668_and_707_reconcile_but_stay_distinct_from_dry_run_family
    gh = FakeGh.new
    gh.issues = [
      legacy_wrapper_issue(668), legacy_dry_run_issue(672), legacy_wrapper_issue(707)
    ]

    result = filer(gh).publish(
      thesis: wrapper_thesis, family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: successful_intent
    )

    assert_equal "issue_linked_open", result.outcome
    assert_equal "https://github.com/acme/demo/issues/668", result.issue_url
    assert_equal [ "https://github.com/acme/demo/issues/707" ],
                 result.receipts.fetch("duplicate_issue_urls")
    assert_empty gh.creates
  end

  def test_matching_but_malformed_legacy_finding_fails_closed
    gh = FakeGh.new
    malformed = legacy_dry_run_issue(672)
    malformed["body"] = malformed.fetch("body").sub(/(?:[#]{2,3} Evidence|Evidence:)\n.*\z/m, "")
    gh.issues = [ malformed ]

    result = filer(gh).publish(
      thesis: dry_run_thesis, family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: successful_intent
    )

    assert_equal "issue_reconcile_failed", result.outcome
    refute result.terminal
    assert_includes result.receipts.fetch("error"), "legacy issue #672"
    assert_empty gh.creates
  end

  def test_matching_legacy_findings_with_invalid_identity_body_or_evidence_fail_closed
    baseline = legacy_dry_run_issue(672)
    malformed_bodies = [
      nil,
      baseline.fetch("body").sub(
        /Feature ID: `command-bin-hive`/,
        "Feature ID: `command-bin-hive`\nFeature ID: `command-bin-hive`"
      ),
      baseline.fetch("body").sub(/[a-f0-9]{64}/, "not-a-fingerprint"),
      baseline.fetch("body").sub(/- `bin\/hive-babysitter-stub-git:1`.*\n/, "- no file anchor\n")
                         .sub(/- `bin\/hive-babysitter-stub-gh:2`.*\n/, "")
    ]

    malformed_bodies.each do |body|
      gh = FakeGh.new
      gh.issues = [ baseline.merge("body" => body) ]

      result = filer(gh).publish(
        thesis: dry_run_thesis, family_id: family_id,
        canonical_action_id: action_id, job_id: "job-7", source: source,
        record_intent: successful_intent
      )

      assert_equal "issue_reconcile_failed", result.outcome
      refute result.terminal
      assert_includes result.receipts.fetch("error"), "legacy issue #672"
      assert_empty gh.creates
    end
  end

  def test_issue_inventory_failure_blocks_creation
    gh = FakeGh.new
    gh.lookup_error = "inventory unavailable"

    result = filer(gh).publish(
      thesis: thesis(flags: [ "cross_feature_impact" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: successful_intent
    )

    assert_equal "issue_reconcile_failed", result.outcome
    refute result.terminal
    assert_includes result.receipts.fetch("error"), "inventory unavailable"
    assert_empty gh.creates
  end

  def test_non_transitive_legacy_matches_are_ambiguous_and_fail_closed
    gh = FakeGh.new
    gh.issues = [
      legacy_issue(
        20, feature_id: "architecture-services-checkout", thesis_id: "extract-a",
        problem: "Checkout repeats validation policy across responsibilities.",
        cost: "Policy edits fan out through checkout validation.",
        proposed: "Consolidate the validation policy behind a shared boundary.",
        anchors: [ "services/checkout/a.ts" ]
      ),
      legacy_issue(
        21, feature_id: "architecture-services-checkout", thesis_id: "extract-b",
        problem: "Checkout repeats validation policy across responsibilities.",
        cost: "Policy edits fan out through checkout validation.",
        proposed: "Consolidate the validation policy behind a shared boundary.",
        anchors: [ "services/checkout/b.ts" ]
      )
    ]
    item = thesis(flags: [ "cross_feature_impact" ])
    item.evidence = %w[a b].map do |name|
      {
        "file" => "services/checkout/#{name}.ts", "line" => 7,
        "claim" => "Checkout validation policy repeats across responsibilities"
      }
    end
    item.feature_boundary = {
      "owned_files" => item.evidence.map { |entry| entry.fetch("file") }, "entrypoints" => []
    }
    item.problem = "Checkout repeats validation policy across responsibilities"
    item.cost = "Policy edits fan out through checkout validation"
    item.proposed_refactor = "Consolidate the validation policy behind a shared boundary"

    result = filer(gh).publish(
      thesis: item, family_id: family_id, canonical_action_id: action_id,
      job_id: "job-7", source: source, record_intent: successful_intent
    )

    assert_equal "issue_reconcile_failed", result.outcome
    refute result.terminal
    assert_includes result.receipts.fetch("error"), "ambiguous legacy issues"
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

  def test_issue_create_fence_rejection_is_known_not_sent_and_can_retry
    gh = FakeGh.new
    intents = 0

    result = filer(gh).publish(
      thesis: thesis(flags: [ "not_single_feature" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: -> { intents += 1; true },
      authorize_create: -> { false }
    )

    assert_equal "authority_revoked", result.outcome
    refute result.terminal
    assert_equal 0, intents
    refute result.receipts.key?("creation_intent")
    assert_empty gh.creates

    retried = filer(gh).publish(
      thesis: thesis(flags: [ "not_single_feature" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: -> { intents += 1; true }
    )
    assert_equal "issue_created", retried.outcome
    assert_equal 1, intents
    assert_equal 1, gh.creates.size
  end

  def test_issue_create_rechecks_authority_after_persisting_intent
    gh = FakeGh.new
    fences = [ true, false ]
    intents = 0

    result = filer(gh).publish(
      thesis: thesis(flags: [ "not_single_feature" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: -> { intents += 1; true },
      authorize_create: -> { fences.shift }
    )

    assert_equal "authority_revoked", result.outcome
    refute result.terminal
    assert_equal 1, intents
    assert_empty gh.creates
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
      thesis(flags: [ "public_api_impact" ], confidence: "low"),
      thesis(flags: [ "public_api_impact" ], admissible: false),
      thesis(flags: [ "public_api_impact" ], score: 0.1),
      thesis(flags: [ "collision_patrol_pr" ]),
      thesis(flags: [ "incomplete_leverage_measurement" ], admissible: false)
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

  def test_deterministic_nonfixable_outcomes_are_issue_eligible
    %w[
      agent_control_plane_violation
      auto_fix_disabled
      boundary_violation
      dependency_change
      fix_guardrail
      missing_validation
      public_contract_change
      public_contract_safety_unavailable
      secret_detected
      symlinked_path
      validation_changed_head
      validation_failed
      validation_mutated_worktree
    ].each do |outcome|
      gh = FakeGh.new

      result = filer(gh).publish(
        thesis: thesis(flags: []), family_id: family_id,
        canonical_action_id: action_id, job_id: "job-7", source: source,
        reasons: [ outcome ], record_intent: successful_intent
      )

      assert_equal "issue_created", result.outcome, outcome
      assert result.terminal, outcome
      assert_equal 1, gh.creates.size, outcome
    end
  end

  def test_documentation_thesis_without_docs_validation_files_one_issue
    gh = FakeGh.new

    result = filer(gh).publish(
      thesis: thesis(
        flags: [ "missing_docs_validation" ],
        feature_id: "documentation-docs-root", boundary_file: "docs/architecture.md",
        validation_commands: []
      ),
      family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: successful_intent
    )

    assert_equal "issue_created", result.outcome
    assert result.terminal
    assert_equal 1, gh.creates.size
    assert_includes gh.creates.first.fetch(:body), "missing_docs_validation"
  end

  def test_issue_disabled_and_secret_content_make_no_remote_call
    disabled_gh = FakeGh.new
    disabled = filer(disabled_gh, enabled: false).publish(
      thesis: thesis(flags: [ "public_api_impact" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: successful_intent
    )
    assert_equal "issue_disabled", disabled.outcome
    assert_empty disabled_gh.lookups

    secret_gh = FakeGh.new
    item = thesis(flags: [ "public_api_impact" ])
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
      thesis: thesis(flags: [ "public_api_impact" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: -> { nil }
    )

    assert_equal "intent_persist_failed", result.outcome
    refute result.terminal
    assert_empty gh.creates
  end

  def test_intent_callback_supports_keyword_receipts_and_wraps_callback_errors
    gh = FakeGh.new
    receipts = []
    created = filer(gh).publish(
      thesis: thesis(flags: [ "public_api_impact" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: ->(**kwargs) { receipts << kwargs; true }
    )

    assert_equal "issue_created", created.outcome
    assert_equal "issue_create_intent", receipts.first.fetch(:phase)
    assert_equal "create_issue", receipts.first.dig(:payload, "operation")

    failed = filer(FakeGh.new).publish(
      thesis: thesis(flags: [ "public_api_impact" ]), family_id: family_id,
      canonical_action_id: action_id, job_id: "job-7", source: source,
      record_intent: ->(**) { raise IOError, "state unavailable" }
    )
    assert_equal "intent_persist_failed", failed.outcome
    assert_includes failed.receipts.fetch("error"), "state unavailable"
  end

  def test_family_and_canonical_action_identity_must_be_durable_ids
    gh = FakeGh.new
    item = thesis(flags: [ "public_api_impact" ])

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

  def thesis(flags:, confidence: "medium", admissible: true, score: 0.4,
             feature_id: "architecture-services-checkout",
             boundary_file: "services/checkout/core.ts", validation_commands: [ "test" ],
             follow_up_approval_state: "pending")
    Hive::RefactorPatrol::Thesis.new(
      id: "extract", feature_id: feature_id, feature: "Checkout",
      problem: "Checkout mixes validation and payment policy",
      cost: "Changes fan out across responsibilities",
      evidence: [
        {
          "file" => boundary_file, "line" => 42,
          "snippet" => "validateAndCharge()", "claim" => "Problem evidence"
        }
      ],
      proposed_refactor: "Extract a payment-policy boundary",
      feature_boundary: { "owned_files" => [ boundary_file ], "entrypoints" => [] },
      expected_leverage: {
        "score" => score, "breakdown" => { "coupling" => score },
        "drivers" => [
          { "signal" => "coupling", "relief" => 0.5, "mechanism" => "isolate repeated edits" }
        ]
      },
      confidence: confidence,
      risk: {
        "flags" => flags, "caps" => { "single_feature" => true },
        "public_api_impact" => false, "public_api_details" => [],
        "cross_feature_impact" => false, "cross_feature_details" => []
      },
      required_validation: {
        "commands" => validation_commands, "characterization_first" => false,
        "notes" => "Run the checkout tests"
      },
      admissible: admissible, admissibility_reason: admissible ? "anchored" : "missing anchor",
      follow_up_approval_state: follow_up_approval_state, fingerprint: "fp-1"
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

  def dry_run_thesis
    item = thesis(
      flags: [ "public_api_impact" ], feature_id: "command-bin-hive",
      boundary_file: "bin/hive-babysitter-stub-git"
    )
    item.feature = "Babysitter dry-run boundary"
    item.problem = <<~TEXT.strip
      The git and gh babysitter dry-run stubs duplicate safety policy classifiers and mix argv
      parsing, environment hardening, skip reporting, and exec handoff responsibilities.
    TEXT
    item.cost = "Dry-run policy edits fan out across both executable stubs and are hard to audit."
    item.proposed_refactor = <<~TEXT.strip
      Consolidate the Git and GH dry-run policy classifiers behind a shared boundary while
      leaving each stub as a thin exec adapter.
    TEXT
    item.evidence = %w[git gh].map do |tool|
      {
        "file" => "bin/hive-babysitter-stub-#{tool}", "line" => 42,
        "claim" => "#{tool} dry-run allowlist policy mixes environment and exec behavior"
      }
    end
    item.feature_boundary = {
      "owned_files" => item.evidence.map { |entry| entry.fetch("file") }, "entrypoints" => []
    }
    item
  end

  def wrapper_thesis
    item = thesis(
      flags: [ "public_api_impact" ], feature_id: "command-bin-hive", boundary_file: "bin/hive"
    )
    item.feature = "CLI wrapper argv contract"
    item.problem = "The CLI wrappers repeat a scattered argv, JSON, help, and encoding contract."
    item.cost = "Wrapper grammar changes fan out across executable dispatch paths."
    item.proposed_refactor = "Consolidate the shared CLI argv contract behind one pre-dispatch boundary."
    item.evidence = %w[bin/hive bin/hive-e2e].map do |file|
      {
        "file" => file, "line" => 21,
        "claim" => "CLI wrapper repeats argv JSON help encoding dispatch grammar"
      }
    end
    item.feature_boundary = {
      "owned_files" => item.evidence.map { |entry| entry.fetch("file") }, "entrypoints" => []
    }
    item
  end

  def legacy_dry_run_issue(number)
    details = {
      672 => {
        problem: "The babysitter git and gh dry-run stubs embed allowlist policy classifiers, argv parsing, environment hardening, and exec handoff.",
        cost: "Dry-run security policy edits are interleaved across both executable stubs.",
        proposed: "Extract git and gh policy classifiers behind a shared dry-run boundary.",
        anchors: %w[bin/hive-babysitter-stub-git bin/hive-babysitter-stub-gh]
      },
      692 => {
        problem: "The git and gh dry-run safety classifiers combine argv policy, environment hardening, skip logging, and exec behavior.",
        cost: "Duplicated classifier patterns make dry-run fixes fan out across the stubs.",
        proposed: "Move both dry-run gates into shared policy objects and keep thin exec adapters.",
        anchors: %w[bin/hive-babysitter-stub-gh bin/hive-babysitter-stub-git lib/hive/babysitter/dry_run_env.rb]
      },
      708 => {
        problem: "The babysitter git and gh dry-run programs mix pure allowlist classification with environment mutation, reporting, and exec.",
        cost: "Shared policy and handoff behavior can drift between both stubs.",
        proposed: "Extract GitPolicy and GhPolicy behind a shared dry-run passthrough boundary.",
        anchors: %w[bin/hive-babysitter-stub-gh bin/hive-babysitter-stub-git]
      }
    }.fetch(number)
    legacy_issue(
      number, feature_id: "command-bin-hive", thesis_id: "dry-run-#{number}", **details,
      markdown_headings: number == 708
    )
  end

  def legacy_wrapper_issue(number)
    details = {
      668 => {
        problem: "The CLI wrapper concentrates argv normalization, help rewriting, JSON errors, encoding checks, and dispatch in bin/hive.",
        cost: "Every wrapper contract change risks parser and executable behavior.",
        proposed: "Extract the pre-dispatch wrapper argv contract behind a small shared boundary.",
        anchors: [ "bin/hive" ]
      },
      707 => {
        problem: "bin/hive and bin/hive-e2e repeat the same CLI argv, JSON, help, encoding, and version grammar.",
        cost: "Wrapper grammar changes require edits in multiple executable dispatch paths.",
        proposed: "Extract shared argv contract primitives and leave both wrappers as thin adapters.",
        anchors: %w[bin/hive bin/hive-e2e]
      }
    }.fetch(number)
    legacy_issue(
      number, feature_id: "command-bin-hive", thesis_id: "wrapper-#{number}", **details,
      markdown_headings: number == 707
    )
  end

  def legacy_issue(number, feature_id:, thesis_id:, problem:, cost:, proposed:, anchors:,
                   markdown_headings: true)
    heading = ->(name) { markdown_headings ? "### #{name}" : "#{name}:" }
    id_prefix = markdown_headings ? "- " : ""
    body = <<~MD
      ## Refactor-patrol finding

      #{id_prefix}Feature ID: `#{feature_id}`
      #{id_prefix}Thesis ID: `#{thesis_id}`
      #{id_prefix}Fingerprint: `#{format('%064x', number)}`

      #{heading.call('Problem')}

      #{problem}

      #{heading.call('Cost')}

      #{cost}

      #{heading.call('Proposed refactor')}

      #{proposed}

      #{heading.call('Evidence')}

      #{anchors.map.with_index { |file, index| "- `#{file}:#{index + 1}` — policy boundary evidence" }.join("\n")}

      ### Validation guidance

      Run focused tests.
    MD
    {
      "number" => number, "state" => "OPEN",
      "url" => "https://github.com/acme/demo/issues/#{number}",
      "title" => "refactor-patrol: #{feature_id} - legacy finding", "body" => body
    }
  end
end
