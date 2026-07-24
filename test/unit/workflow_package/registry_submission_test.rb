require "digest"
require "test_helper"
require "hive/workflow_package/publisher"
require "hive/workflow_package/registry_submission"

class WorkflowPackageRegistrySubmissionTest < Minitest::Test
  include HiveTestHelper

  PullRequest = Hive::WorkflowPackage::RegistryGateway::PullRequest

  class FakeGateway
    attr_reader :mutations, :verified_forks, :version_checks

    def initialize(package, direct: false, fail_push: false, version_after_prepare: nil)
      @package = package
      @direct = direct
      @fail_push = fail_push
      @version_after_prepare = version_after_prepare
      @mutations = []
      @verified_forks = []
      @version_checks = 0
      @pushed = false
      @pr = nil
    end

    def authenticate! = "alice"
    def pull_requests(_repository) = @pr ? [ @pr ] : []

    def version_present?(_repository, _ref, _package)
      @version_checks += 1
      @version_after_prepare if @version_checks > 1
    end

    def direct_permission?(_repository, _login) = @direct
    def base_oid(_repository, _branch) = "b" * 40

    def ensure_fork(repository, login)
      @mutations << :fork
      "#{login}/#{repository.split('/').last}"
    end

    def verify_fork!(repository, parent:, owner:)
      @verified_forks << [ repository, parent, owner ]
      true
    end

    def commit_parent_oid(_repository, _oid) = "b" * 40

    def prepare_commit(*_args, **_kwargs) = [ "/retained/objects", "c" * 40 ]

    def branch_oid(_repository, _branch)
      @pushed ? "c" * 40 : nil
    end

    def push_expected_absent(_checkout, _branch, _oid)
      @mutations << :push
      if @fail_push
        @pushed = true if @fail_push == :after
        raise Hive::WorkflowPackage::PublishAmbiguousError, "unknown"
      end
      @pushed = true
    end

    def verify_remote_package!(_repository, _ref, package)
      raise "wrong package" unless package.release_digest == @package.release_digest
      true
    end

    def create_pull_request(repository:, base_branch:, head_repository:, branch:, package:)
      @mutations << :pr
      @pr = PullRequest.new(
        number: 42, url: "https://github.com/#{repository}/pull/42", state: "OPEN", draft: false,
        merged_at: nil, head_repository: head_repository, head_branch: branch, head_oid: "c" * 40,
        base_branch: base_branch, body: Hive::WorkflowPackage::RegistryGateway.pr_body(package)
      )
      @pr.url
    end

    def seed_pull_request(package, owner: "bob", branch: "contribution/demo")
      @pushed = true
      @pr = PullRequest.new(
        number: 41, url: "https://github.com/ivankuznetsov/honeycomb/pull/41",
        state: "OPEN", draft: false, merged_at: nil,
        head_repository: "#{owner}/honeycomb", head_branch: branch,
        head_oid: "c" * 40, base_branch: "main",
        body: Hive::WorkflowPackage::RegistryGateway.pr_body(package)
      )
    end
  end

  def test_fork_submission_persists_intents_and_retries_the_same_pr
    with_package do |package|
      with_tmp_dir do |state|
        gateway = FakeGateway.new(package)
        submission = submission_for(state, gateway)

        first = submission.submit(package)
        assert_equal "https://github.com/ivankuznetsov/honeycomb/pull/42", first.pull_request.url
        assert_equal "pr_verified", first.receipt.last_completed_step
        assert_equal "fork", first.receipt.data.fetch("submission_mode")
        assert_equal %i[fork push pr], gateway.mutations

        second = submission.submit(package)
        assert_equal first.pull_request.url, second.pull_request.url
        assert_equal %i[fork push pr], gateway.mutations
      end
    end
  end

  def test_direct_submission_never_creates_a_fork
    with_package do |package|
      with_tmp_dir do |state|
        gateway = FakeGateway.new(package, direct: true)
        result = submission_for(state, gateway).submit(package)
        assert_equal "direct", result.receipt.data.fetch("submission_mode")
        assert_equal %i[push pr], gateway.mutations
      end
    end
  end

  def test_unknown_push_outcome_retains_push_intent_for_reconciliation
    with_package do |package|
      with_tmp_dir do |state|
        gateway = FakeGateway.new(package, fail_push: true)
        assert_raises(Hive::WorkflowPackage::PublishAmbiguousError) do
          submission_for(state, gateway).submit(package)
        end
        receipt = Hive::WorkflowPackage::PublishStore.new(root: state)
                                                       .load("ivankuznetsov/honeycomb", "demo", "1.0.0")
        assert_equal "push_intent", receipt.last_completed_step
        assert_equal "c" * 40, receipt.data.fetch("commit_oid")
      end
    end
  end

  def test_lost_successful_push_response_resumes_without_a_second_push
    with_package do |package|
      with_tmp_dir do |state|
        gateway = FakeGateway.new(package, fail_push: :after)
        submission = submission_for(state, gateway)
        assert_raises(Hive::WorkflowPackage::PublishAmbiguousError) { submission.submit(package) }
        gateway.instance_variable_set(:@fail_push, false)

        result = submission.submit(package)
        assert_equal "pr_verified", result.receipt.last_completed_step
        assert_equal 1, gateway.mutations.count(:push)
        assert_equal 1, gateway.mutations.count(:pr)
      end
    end
  end

  def test_same_version_different_digest_conflicts_before_remote_replacement
    with_package do |package|
      with_tmp_dir do |state|
        gateway = FakeGateway.new(package)
        submission = submission_for(state, gateway)
        submission.submit(package)
        changed = package.with(package_digest: "d" * 64)
        assert_raises(Hive::WorkflowPackage::PublishConflict) { submission.submit(changed) }
        assert_equal %i[fork push pr], gateway.mutations
      end
    end
  end

  def test_pr_body_binds_both_digests_and_forbidden_actions_are_absent
    with_package do |package|
      body = Hive::WorkflowPackage::RegistryGateway.pr_body(package)
      assert_includes body, package.package_digest
      assert_includes body, package.release_digest
      assert_includes body, "asterio/hive#705"
      refute_match(/force-push|automatically merge|catalogue edit/i, body)
    end
  end

  def test_matching_external_pr_is_adopted_by_verified_identity_not_branch_name
    with_package do |package|
      with_tmp_dir do |state|
        gateway = FakeGateway.new(package)
        gateway.seed_pull_request(package)

        result = submission_for(state, gateway).submit(package)

        assert_equal "https://github.com/ivankuznetsov/honeycomb/pull/41", result.pull_request.url
        assert_equal "contribution/demo", result.receipt.data.fetch("head_branch")
        assert_equal "alice", result.receipt.data.fetch("owner")
        assert_equal "bob", result.receipt.data.fetch("fork_owner")
        assert_equal(
          [ [ "bob/honeycomb", "ivankuznetsov/honeycomb", "bob" ] ],
          gateway.verified_forks
        )
        assert_empty gateway.mutations
      end
    end
  end

  def test_policy_block_allows_discovery_but_stops_new_remote_mutations
    with_package do |package|
      with_tmp_dir do |state|
        gateway = FakeGateway.new(package)
        error = assert_raises(Hive::WorkflowPackage::PublishPolicyBlocked) do
          submission_for(state, gateway).submit(package, allow_mutation: false)
        end

        assert_match(/current Honeycomb lint policy/, error.message)
        assert_empty gateway.mutations
      end
    end
  end

  def test_target_version_is_rechecked_immediately_before_first_push
    with_package do |package|
      with_tmp_dir do |state|
        identity = { package_digest: "d" * 64, release_digest: "e" * 64 }
        gateway = FakeGateway.new(package, direct: true, version_after_prepare: identity)

        assert_raises(Hive::WorkflowPackage::PublishConflict) do
          submission_for(state, gateway).submit(package)
        end
        assert_operator gateway.version_checks, :>=, 2
        refute_includes gateway.mutations, :push
      end
    end
  end

  private

  def submission_for(root, gateway)
    Hive::WorkflowPackage::RegistrySubmission.new(
      registry: "ivankuznetsov/honeycomb", base_branch: "main", gateway: gateway,
      store: Hive::WorkflowPackage::PublishStore.new(root: root)
    )
  end

  def with_package
    with_tmp_dir do |root|
      manifest = write_package(root)
      package = Hive::WorkflowPackage::Publisher::Package.new(
        name: "demo", version: "1.0.0", root: root,
        package_digest: Digest::SHA256.file(File.join(root, "manifest.yml")).hexdigest,
        release_digest: manifest.fetch("release_sha256"), warnings: [], findings: [],
        lint_contract: {
          "version" => "v1", "upstream_commit" => "a" * 40,
          "upstream_policy_sha256" => "c" * 64,
          "fixture_corpus_sha256" => "d" * 64,
          "expected_output_sha256" => "e" * 64,
          "contract_sha256" => "b" * 64
        }
      )
      yield package
    end
  end

  def write_package(root)
    FileUtils.mkdir_p(File.join(root, "instructions"))
    File.write(File.join(root, "README.md"), "# Demo\n")
    File.write(File.join(root, "instructions", "work.md"), "Read files only.\n")
    File.write(File.join(root, "workflow.yml"), <<~YAML)
      id: demo
      stages:
        - name: inbox
          kind: terminal
          state_file: idea.md
        - name: work
          kind: agent
          state_file: work.md
          advance_verb: work
          instruction: instructions/work.md
          permissions: read-only
          mapping_role: development
          mapping_contract: demo-work-v1
        - name: done
          kind: terminal
          state_file: done.md
          advance_verb: done
    YAML
    prefix = "packages/demo/1.0.0/"
    files = %w[README.md instructions/work.md workflow.yml].to_h do |relative|
      [ "#{prefix}#{relative}", Digest::SHA256.file(File.join(root, relative)).hexdigest ]
    end
    manifest = {
      "schema" => "honeycomb-manifest/v1", "name" => "demo", "version" => "1.0.0",
      "description" => "Demo", "author" => { "name" => "Test", "url" => "https://example.test/test" },
      "license" => "MIT", "hive_min_version" => "0.4.3",
      "source" => { "url" => "https://example.test/source", "revision" => "c" * 40 },
      "permissions" => {
        "risk" => "low", "capabilities" => [ "filesystem-read" ], "network_hosts" => [],
        "filesystem_read" => [ "repository", "task" ], "filesystem_write" => [], "secrets" => []
      },
      "files" => files, "x-hive" => { "external_skills" => [], "optional_inputs" => [], "tools" => [] }
    }
    manifest["release_sha256"] = Digest::SHA256.hexdigest(
      Hive::WorkflowPackage::CanonicalYAML.dump_manifest(manifest, include_release: false)
    )
    File.binwrite(
      File.join(root, "manifest.yml"), Hive::WorkflowPackage::CanonicalYAML.dump_manifest(manifest)
    )
    manifest
  end
end
