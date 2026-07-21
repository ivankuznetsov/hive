require "json"
require "time"
require "hive/workflow_package/publish_store"
require "hive/workflow_package/registry_gateway"

module Hive
  module WorkflowPackage
    class RegistrySubmission
      Result = Data.define(:receipt, :pull_request)
      METADATA = /<!-- hive-workflow-publish:v1 (\{[^\n]+\}) -->/

      def initialize(registry:, base_branch:, gateway: RegistryGateway.new, store: PublishStore.new)
        unless PublishReceipt::REPOSITORY.match?(registry.to_s)
          raise Hive::ConfigError, "Honeycomb registry repository must be owner/name"
        end
        unless PublishReceipt::BRANCH.match?(base_branch.to_s)
          raise Hive::ConfigError, "Honeycomb registry base branch is invalid"
        end
        @registry = registry
        @base_branch = base_branch
        @gateway = gateway
        @store = store
      end

      def submit(package)
        receipt = @store.create_or_load(package, registry: @registry)
        @store.verify_bundle(receipt)
        login = @gateway.authenticate!
        branch = "honeycomb-#{package.name}-#{package.version}-#{package.release_digest[0, 12]}"
        candidate = reconcile_candidates!(@gateway.pull_requests(@registry), package, branch)
        return Result.new(receipt: adopt(receipt, candidate, package), pull_request: candidate) if candidate

        base_identity = @gateway.version_present?(@registry, @base_branch, package)
        raise_immutable_version!(base_identity, package) if base_identity

        if receipt.last_completed_step == "validated"
          mode = @gateway.direct_permission?(@registry, login) ? "direct" : "fork"
          head_repository = mode == "direct" ? @registry : "#{login}/#{@registry.split('/').last}"
          base_oid = @gateway.base_oid(@registry, @base_branch)
          receipt = prepare(receipt, login, branch, head_repository, mode, base_oid)
        else
          validate_retained_destination!(receipt, login, branch)
          mode = receipt.data["submission_mode"] || "fork"
          head_repository = receipt.data.fetch("head_repository")
          base_oid = receipt.data.fetch("base_sha")
        end
        if mode == "fork" && !at_least?(receipt, "fork_verified")
          begin
            receipt = save(receipt.advance("fork_create_intent")) unless at_least?(receipt, "fork_create_intent")
            verified_fork = @gateway.ensure_fork(@registry, login)
          rescue PublishConflict
            raise
          rescue StandardError
            raise PublishAmbiguousError, "registry fork outcome is unknown"
          end
          raise PublishConflict, "verified fork does not match the publication receipt" unless verified_fork == head_repository
          receipt = save(receipt.advance(
            "fork_verified", submission_mode: "fork", fork_parent: @registry, fork_owner: login
          ))
        end

        checkout, commit_oid = @gateway.prepare_commit(
          package, repository: @registry, base_branch: @base_branch, base_oid: base_oid,
          head_repository: head_repository, branch: branch
        )
        remote_oid = @gateway.branch_oid(head_repository, branch)
        if remote_oid
          verify_branch!(remote_oid, commit_oid, head_repository, branch, package)
        else
          if at_least?(receipt, "pushed")
            raise PublishConflict, "a previously verified publication branch was removed"
          end
          unless at_least?(receipt, "push_intent")
            receipt = save(receipt.advance("push_intent", commit_oid: commit_oid))
          end
          @gateway.push_expected_absent(checkout, branch, commit_oid)
          remote_oid = @gateway.branch_oid(head_repository, branch)
          verify_branch!(remote_oid, commit_oid, head_repository, branch, package)
        end
        receipt = save(receipt.advance("pushed", commit_oid: commit_oid)) unless at_least?(receipt, "pushed")

        receipt = save(receipt.advance("pr_create_intent")) unless at_least?(receipt, "pr_create_intent")
        @gateway.create_pull_request(
          repository: @registry, base_branch: @base_branch,
          head_repository: head_repository, branch: branch, package: package
        )
        candidate = reconcile_candidates!(@gateway.pull_requests(@registry), package, branch)
        raise PublishAmbiguousError, "registry pull-request outcome is unknown" unless candidate

        Result.new(receipt: adopt(receipt, candidate, package), pull_request: candidate)
      end

      private

      def at_least?(receipt, step)
        PublishReceipt::STEPS.index(receipt.last_completed_step) >= PublishReceipt::STEPS.index(step)
      end

      def validate_retained_destination!(receipt, login, branch)
        unless receipt.data["destination_repository"] == @registry &&
               receipt.data["base_branch"] == @base_branch && receipt.data["owner"] == login &&
               receipt.data["head_branch"] == branch
          raise PublishConflict, "retained publication destination or authenticated owner changed"
        end
      end

      def prepare(receipt, login, branch, head_repository, mode, base_oid)
        attributes = {
          destination_repository: @registry, base_branch: @base_branch,
          base_sha: base_oid, head_repository: head_repository,
          head_branch: branch, owner: login
        }
        attributes[:submission_mode] = "direct" if mode == "direct"
        save(receipt.advance("prepared", attributes))
      end

      def reconcile_candidates!(pull_requests, package, branch)
        same_version = pull_requests.filter_map do |pr|
          metadata = parse_metadata(pr.body)
          next unless metadata && metadata["name"] == package.name && metadata["version"] == package.version
          [ pr, metadata ]
        end
        conflicts = same_version.reject do |_pr, metadata|
          metadata["release_digest"] == package.release_digest && metadata["package_digest"] == package.package_digest
        end
        raise PublishConflict, "workflow version already has a different immutable submission" unless conflicts.empty?
        matches = same_version.select do |pr, metadata|
          pr.head_branch == branch && metadata["release_digest"] == package.release_digest &&
            metadata["package_digest"] == package.package_digest
        end
        raise PublishConflict, "multiple pull requests claim the same immutable submission" if matches.length > 1
        return nil if matches.empty?

        pr = matches.first.first
        raise PublishConflict, "registry pull request is draft or targets the wrong base" if pr.draft || pr.base_branch != @base_branch
        @gateway.verify_remote_package!(pr.head_repository, pr.head_oid, package)
        remote_oid = @gateway.branch_oid(pr.head_repository, pr.head_branch)
        raise PublishConflict, "registry pull request head no longer matches its branch" unless remote_oid == pr.head_oid
        pr
      end

      def adopt(receipt, pr, _package)
        owner = receipt.data["owner"] || pr.head_repository.split("/", 2).first
        mode = receipt.data["submission_mode"] || (pr.head_repository == @registry ? "direct" : "fork")
        attributes = {
          submission_mode: mode, destination_repository: @registry, base_branch: @base_branch,
          head_repository: pr.head_repository, head_branch: pr.head_branch, owner: owner,
          commit_oid: pr.head_oid, pr_number: pr.number, pr_url: pr.url
        }
        attributes.merge!(fork_parent: @registry, fork_owner: owner) if mode == "fork"
        receipt = save(receipt.advance("pr_verified", attributes))
        state = case pr.state
        when "OPEN" then "pending_review"
        when "MERGED" then "merged_pending_listing"
        else "closed_unmerged"
        end
        save(receipt.observe(state: state, observed_at: Time.now.utc.iso8601, pr_url: pr.url, pr_number: pr.number))
      rescue PublishRecoveryError
        raise PublishConflict, "remote pull request identity conflicts with retained publication state"
      end

      def verify_branch!(remote_oid, commit_oid, repository, branch, package)
        raise PublishAmbiguousError, "registry branch outcome is unknown" unless remote_oid
        raise PublishConflict, "registry branch commit does not match the retained commit" unless remote_oid == commit_oid
        @gateway.verify_remote_package!(repository, branch, package)
      end

      def raise_immutable_version!(identity, package)
        if identity[:release_digest] == package.release_digest && identity[:package_digest] == package.package_digest
          raise PublishConflict, "workflow version is already merged and cannot be republished from new local state"
        end
        raise PublishConflict, "workflow version is already immutable with different package bytes"
      end

      def parse_metadata(body)
        match = METADATA.match(body.to_s)
        return nil unless match
        value = JSON.parse(match[1])
        value if value.is_a?(Hash)
      rescue JSON::ParserError
        raise PublishConflict, "registry pull request carries malformed Hive publication metadata"
      end

      def save(receipt) = @store.save(receipt)
    end
  end
end
