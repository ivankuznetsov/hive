require "time"
require "hive/workflow_package/publish_store"
require "hive/workflow_package/registry_client"
require "hive/workflow_package/registry_gateway"

module Hive
  module WorkflowPackage
    class PublishResolver
      Result = Data.define(:state, :freshness, :observed_at, :pr_url, :warnings, :receipt)
      Evidence = Data.define(
        :name, :version, :root, :package_digest, :release_digest,
        :warnings, :lint_contract, :findings
      ) do
        def registry_path = "packages/#{name}/#{version}"
      end

      def initialize(registry:, gateway:, catalogue:, store:, clock: nil)
        @registry = registry
        @gateway = gateway
        @catalogue = catalogue
        @store = store
        @clock = clock || -> { Time.now.utc }
      end

      def resolve(receipt)
        root = @store.verify_bundle(receipt)
        package = evidence(receipt, root)
        catalogue = @catalogue.observe(
          name: receipt.name, version: receipt.version, release_digest: receipt.release_digest
        )
        if catalogue.listed
          return persist(receipt, "listed", pr_url: receipt.data["pr_url"], pr_number: receipt.data["pr_number"])
        end

        pr = exact_pull_request!(receipt, package)
        state = case pr.state
        when "OPEN" then "pending_review"
        when "MERGED" then "merged_pending_listing"
        when "CLOSED" then "closed_unmerged"
        else raise PublishRecoveryError, "registry pull request lifecycle is unsupported"
        end
        persist(receipt, state, pr_url: pr.url, pr_number: pr.number)
      rescue CatalogueUnavailable, PublishOfflineError => e
        cached(receipt, e)
      end

      private

      def evidence(receipt, root)
        Evidence.new(
          name: receipt.name, version: receipt.version, root: root,
          package_digest: receipt.package_digest, release_digest: receipt.release_digest,
          warnings: [], lint_contract: receipt.lint_contract, findings: []
        ).freeze
      end

      def exact_pull_request!(receipt, package)
        number = receipt.data["pr_number"]
        raise PublishRecoveryError, "publication receipt has no verified pull request" unless number
        matches = @gateway.pull_requests(@registry).select { |candidate| candidate.number == number }
        raise PublishRecoveryError, "verified registry pull request is missing" unless matches.one?
        pr = matches.first
        unless pr.url == receipt.data["pr_url"] && pr.head_repository == receipt.data["head_repository"] &&
               pr.head_branch == receipt.data["head_branch"] && pr.head_oid == receipt.data["commit_oid"] &&
               pr.base_branch == receipt.data["base_branch"] && !pr.draft
          raise PublishRecoveryError, "registry pull request identity drifted from its receipt"
        end
        branch_oid = @gateway.branch_oid(pr.head_repository, pr.head_branch)
        raise PublishRecoveryError, "registry pull request branch identity drifted" unless branch_oid == pr.head_oid
        @gateway.verify_remote_package!(pr.head_repository, pr.head_oid, package)
        pr
      end

      def persist(receipt, state, pr_url:, pr_number:)
        observed_at = @clock.call.utc.iso8601
        updated = @store.save(
          receipt.observe(state: state, observed_at: observed_at, pr_url: pr_url, pr_number: pr_number)
        )
        Result.new(
          state: state, freshness: "current", observed_at: observed_at,
          pr_url: pr_url, warnings: [], receipt: updated
        ).freeze
      end

      def cached(receipt, error)
        raise PublishOfflineError, "publication lifecycle is unavailable and has no cached observation" unless receipt.observation
        observation = receipt.cached_observation
        Result.new(
          state: observation.fetch("state"), freshness: "cached",
          observed_at: observation.fetch("observed_at"),
          pr_url: observation["pr_url"],
          warnings: [ {
            "rule_id" => "publish.cached_observation", "path" => "receipt",
            "message" => "remote lifecycle is unavailable; returning the prior observation",
            "detail" => error.class.name.split("::").last
          } ].freeze,
          receipt: receipt
        ).freeze
      end
    end
  end
end
