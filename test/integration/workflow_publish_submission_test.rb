require "test_helper"
require "hive/workflow_package/publisher"
require "hive/workflow_package/publish_resolver"
require "hive/workflow_package/registry_submission"

class WorkflowPublishSubmissionIntegrationTest < Minitest::Test
  include HiveTestHelper

  PullRequest = Hive::WorkflowPackage::RegistryGateway::PullRequest
  Observation = Hive::WorkflowPackage::RegistryClient::CatalogueObservation

  class Remote
    attr_reader :mutation_count

    def initialize(package)
      @package = package
      @mutation_count = Hash.new(0)
      @branch_oid = nil
      @pr = nil
    end

    def authenticate! = "alice"
    def pull_requests(_repository) = @pr ? [ @pr ] : []
    def version_present?(_repository, ref, _package)
      return nil unless @pr && ref == @pr.head_oid
      {
        package_digest: @package.package_digest,
        release_digest: @package.release_digest
      }
    end
    def direct_permission?(_repository, _login) = false
    def base_oid(_repository, _branch) = "b" * 40

    def ensure_fork(repository, login)
      @mutation_count[:fork] += 1
      "#{login}/#{repository.split('/').last}"
    end

    def verify_fork!(_repository, parent:, owner:)
      raise "wrong fork parent" unless parent == "ivankuznetsov/honeycomb" && owner == "alice"
      true
    end

    def commit_parent_oid(_repository, _oid) = "b" * 40

    def prepare_commit(*_args, **_kwargs) = [ "/retained/commit", "c" * 40 ]
    def branch_oid(_repository, _branch) = @branch_oid

    def push_expected_absent(_checkout, _branch, oid)
      @mutation_count[:push] += 1
      raise "branch replaced" if @branch_oid
      @branch_oid = oid
    end

    def verify_remote_package!(_repository, _ref, package)
      raise "release changed" unless package.release_digest == @package.release_digest
      true
    end

    def cleanup_commit(_package, repository:) = false

    def create_pull_request(repository:, base_branch:, head_repository:, branch:, package:)
      @mutation_count[:pr] += 1
      raise "duplicate PR" if @pr
      @pr = PullRequest.new(
        number: 52, url: "https://github.com/#{repository}/pull/52", state: "OPEN", draft: false,
        merged_at: nil, head_repository: head_repository, head_branch: branch,
        head_oid: @branch_oid, base_branch: base_branch,
        body: Hive::WorkflowPackage::RegistryGateway.pr_body(package)
      )
      @pr.url
    end

    def merge!
      @pr = @pr.with(state: "MERGED", merged_at: "2026-07-21T13:00:00Z")
    end
  end

  class Catalogue
    attr_writer :listed

    def initialize
      @listed = false
    end

    def observe(**_identity)
      Observation.new(listed: @listed, catalog_commit: "d" * 40, entry: @listed ? {} : nil)
    end
  end

  def test_validated_bytes_converge_on_one_pr_then_exact_listing
    with_authored_project do |project|
      Dir.mktmpdir("workflow-publish-package-") do |package_root|
        package = Hive::WorkflowPackage::Publisher.new(
          "demo", project_root: project, version: "1.0.0"
        ).package(destination: package_root)
        with_tmp_dir do |state|
          store = Hive::WorkflowPackage::PublishStore.new(root: state)
          remote = Remote.new(package)
          submission = Hive::WorkflowPackage::RegistrySubmission.new(
            registry: "ivankuznetsov/honeycomb", base_branch: "main",
            gateway: remote, store: store,
            clock: -> { Time.iso8601("2026-07-21T11:00:00Z") }
          )
          receipt = submission.submit(package).receipt
          catalogue = Catalogue.new
          resolver = Hive::WorkflowPackage::PublishResolver.new(
            registry: "ivankuznetsov/honeycomb", gateway: remote,
            catalogue: catalogue, store: store,
            clock: -> { Time.iso8601("2026-07-21T12:00:00Z") }
          )

          assert_equal "pending_review", resolver.resolve(receipt).state
          remote.merge!
          merged = resolver.resolve(store.load("ivankuznetsov/honeycomb", "demo", "1.0.0"))
          assert_equal "merged_pending_listing", merged.state
          catalogue.listed = true
          listed = resolver.resolve(store.load("ivankuznetsov/honeycomb", "demo", "1.0.0"))
          assert_equal "listed", listed.state
          assert_equal({ fork: 1, push: 1, pr: 1 }, remote.mutation_count)
        end
      end
    end
  end

  private

  def with_authored_project
    with_tmp_dir do |project|
      workflows = File.join(project, ".hive-state", "workflows")
      authored = File.join(workflows, "demo")
      FileUtils.mkdir_p(authored)
      File.write(File.join(workflows, "demo.yml"), <<~YAML)
        id: demo
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: work
            kind: agent
            state_file: work.md
            advance_verb: work
            instruction: ./demo/work.md
            mapping_role: development
            mapping_contract: demo-work-v1
            permissions: read-only
          - name: done
            kind: terminal
            state_file: done.md
            advance_verb: done
      YAML
      File.write(File.join(authored, "work.md"), "Read the task and produce a concise result.\n")
      File.write(File.join(authored, "README.md"), <<~MARKDOWN)
        # Demo

        ## Behavior
        Produces a concise task result.
        ## Prerequisites
        Requires readable task files.
        ## Inputs
        Reads the task brief.
        ## Outputs
        Produces a work result.
        ## Permissions and Risks
        Uses read-only file access.
        ## Recovery
        Retry with the same immutable inputs.
      MARKDOWN
      File.write(File.join(authored, "honeycomb.yml"), <<~YAML)
        description: Produce a concise task result
        author:
          name: Test Author
          url: https://example.test/authors/test
        license: MIT
        hive_min_version: #{Hive::VERSION}
        source:
          url: https://example.test/source/demo
          revision: #{"a" * 40}
        assets: []
      YAML
      yield project
    end
  end
end
