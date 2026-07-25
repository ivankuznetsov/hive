require "test_helper"
require "hive/workflow_package/publish_resolver"

class WorkflowPackagePublishResolverTest < Minitest::Test
  PullRequest = Hive::WorkflowPackage::RegistryGateway::PullRequest
  Observation = Hive::WorkflowPackage::RegistryClient::CatalogueObservation

  class Store
    attr_reader :saved

    def verify_bundle(_receipt) = "/retained/package"

    def update(_registry, _name, _version)
      @saved = yield(@receipt)
    end

    def receipt=(receipt)
      @receipt = receipt
    end
  end

  class Catalogue
    def initialize(listed: false, error: nil)
      @listed = listed
      @error = error
    end

    def observe(**_identity)
      raise @error if @error
      Observation.new(listed: @listed, catalog_commit: "d" * 40, entry: @listed ? {} : nil)
    end
  end

  class Gateway
    def initialize(pr:, error: nil, parent_oid: "b" * 40)
      @pr = pr
      @error = error
      @parent_oid = parent_oid
    end

    def pull_requests(_registry)
      raise @error if @error
      [ @pr ]
    end

    def branch_oid(_repository, _branch) = @pr.head_oid
    def commit_parent_oid(_repository, _oid) = @parent_oid
    def verify_remote_package!(_repository, _ref, _package) = true
  end

  def test_maps_open_merged_and_closed_pr_states
    { "OPEN" => "pending_review", "MERGED" => "merged_pending_listing", "CLOSED" => "closed_unmerged" }.each do |remote, state|
      receipt = receipt_for(remote)
      result = resolver(receipt, catalogue: Catalogue.new, gateway: Gateway.new(pr: pr(remote))).resolve(receipt)
      assert_equal state, result.state
      assert_equal "current", result.freshness
      assert_equal "2026-07-21T12:00:00Z", result.observed_at
    end
  end

  def test_exact_catalogue_is_authoritatively_listed_without_github_read
    receipt = receipt_for("MERGED")
    gateway = Gateway.new(pr: pr("MERGED"), error: RuntimeError.new("must not read GitHub"))
    result = resolver(receipt, catalogue: Catalogue.new(listed: true), gateway: gateway).resolve(receipt)
    assert_equal "listed", result.state
    assert_equal "current", result.freshness
  end

  def test_exact_catalogue_advances_even_a_prior_closed_observation
    receipt = receipt_for("CLOSED").observe(
      state: "closed_unmerged", observed_at: "2026-07-21T11:00:00Z",
      pr_url: pr("CLOSED").url, pr_number: 42
    )

    result = resolver(
      receipt, catalogue: Catalogue.new(listed: true),
      gateway: Gateway.new(pr: pr("CLOSED"), error: RuntimeError.new("must not read GitHub"))
    ).resolve(receipt)

    assert_equal "listed", result.state
  end

  def test_offline_uses_original_cached_observation_time
    receipt = receipt_for("OPEN").observe(
      state: "pending_review", observed_at: "2026-07-20T08:00:00Z",
      pr_url: pr("OPEN").url, pr_number: 42
    )
    catalogue = Catalogue.new(error: Hive::WorkflowPackage::CatalogueUnavailable.new("offline"))
    result = resolver(receipt, catalogue: catalogue, gateway: Gateway.new(pr: pr("OPEN"))).resolve(receipt)
    assert_equal "pending_review", result.state
    assert_equal "cached", result.freshness
    assert_equal "2026-07-20T08:00:00Z", result.observed_at
    assert_equal "publish.cached_observation", result.warnings.first.fetch("rule_id")
  end

  def test_first_offline_observation_is_retryable_not_current
    receipt = receipt_for("OPEN")
    catalogue = Catalogue.new(error: Hive::WorkflowPackage::CatalogueUnavailable.new("offline"))
    assert_raises(Hive::WorkflowPackage::PublishOfflineError) do
      resolver(receipt, catalogue: catalogue, gateway: Gateway.new(pr: pr("OPEN"))).resolve(receipt)
    end
  end

  def test_pr_identity_drift_fails_closed
    receipt = receipt_for("OPEN")
    changed = pr("OPEN").with(head_oid: "e" * 40)
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      resolver(receipt, catalogue: Catalogue.new, gateway: Gateway.new(pr: changed)).resolve(receipt)
    end
  end

  def test_concurrent_stale_observation_cannot_regress_a_newer_lifecycle
    receipt = receipt_for("OPEN").observe(
      state: "merged_pending_listing", observed_at: "2026-07-21T11:30:00Z",
      pr_url: pr("OPEN").url, pr_number: 42
    )

    result = resolver(
      receipt, catalogue: Catalogue.new, gateway: Gateway.new(pr: pr("OPEN"))
    ).resolve(receipt)

    assert_equal "merged_pending_listing", result.state
    assert_equal "2026-07-21T11:30:00Z", result.observed_at
  end

  def test_unsupported_remote_state_and_commit_parent_drift_fail_closed
    receipt = receipt_for("OPEN")
    unsupported = pr("OPEN").with(state: "UNKNOWN")
    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      resolver(
        receipt, catalogue: Catalogue.new, gateway: Gateway.new(pr: unsupported)
      ).resolve(receipt)
    end

    assert_raises(Hive::WorkflowPackage::PublishRecoveryError) do
      resolver(
        receipt, catalogue: Catalogue.new,
        gateway: Gateway.new(pr: pr("OPEN"), parent_oid: "e" * 40)
      ).resolve(receipt)
    end
  end

  private

  def resolver(_receipt, catalogue:, gateway:)
    store = Store.new
    store.receipt = _receipt
    Hive::WorkflowPackage::PublishResolver.new(
      registry: "ivankuznetsov/honeycomb", gateway: gateway, catalogue: catalogue,
      store: store, clock: -> { Time.iso8601("2026-07-21T12:00:00Z") }
    )
  end

  def receipt_for(remote_state)
    Hive::WorkflowPackage::PublishReceipt.build(
      registry: "ivankuznetsov/honeycomb", name: "demo", version: "1.0.0",
      package_digest: "a" * 64, release_digest: "b" * 64,
      lint_contract: {
        "version" => "v1", "upstream_commit" => "c" * 40,
        "upstream_policy_sha256" => "e" * 64,
        "fixture_corpus_sha256" => "f" * 64,
        "expected_output_sha256" => "0" * 64,
        "contract_sha256" => "d" * 64
      }
    ).advance(
      "pr_verified", submission_mode: "direct", destination_repository: "ivankuznetsov/honeycomb",
      base_branch: "main", base_sha: "b" * 40, head_repository: "ivankuznetsov/honeycomb",
      head_branch: "honeycomb-demo-1.0.0-#{'b' * 12}", owner: "alice", commit_oid: "c" * 40,
      pr_number: 42, pr_url: pr(remote_state).url
    )
  end

  def pr(state)
    PullRequest.new(
      number: 42, url: "https://github.com/ivankuznetsov/honeycomb/pull/42", state: state,
      draft: false, merged_at: state == "MERGED" ? "2026-07-21T11:00:00Z" : nil,
      head_repository: "ivankuznetsov/honeycomb",
      head_branch: "honeycomb-demo-1.0.0-#{'b' * 12}", head_oid: "c" * 40,
      base_branch: "main", body: ""
    )
  end
end
