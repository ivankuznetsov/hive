require "test_helper"
require "tmpdir"
require "open3"
require "hive/github_publication"

class GithubPublicationTest < Minitest::Test
  include HiveTestHelper

  class FakeGithub
    attr_reader :creates
    attr_accessor :records, :crash_after_create, :fail_before_create,
                  :definite_fail_before_create, :invalid_inventory, :list_error

    def initialize(records: [])
      @records = records
      @creates = 0
      @crash_after_create = false
      @fail_before_create = false
      @definite_fail_before_create = false
      @invalid_inventory = false
      @list_error = false
    end

    def authenticate!(**)
      true
    end

    def list_pull_requests(**)
      raise Hive::GhError, "remote list failed with sensitive-looking details" if list_error
      return {} if invalid_inventory

      records
    end

    def create_pull_request(request:, **)
      @creates += 1
      if definite_fail_before_create
        raise Hive::GithubPublication::GithubGateway::DefiniteCreateFailure,
              "create was rejected"
      end
      raise Hive::GhError, "create failed before a response" if fail_before_create
      number = 40 + creates
      records << owned_pr(request, number: number)
      raise Hive::GhError, "lost create response" if crash_after_create

      records.last
    end

    def owned_pr(request, number: 42, state: "OPEN", draft: false, overrides: {})
      {
        "number" => number,
        "url" => "https://github.com/acme/demo/pull/#{number}",
        "state" => state,
        "draft" => draft,
        "head_branch" => request.branch,
        "head_oid" => request.head_oid,
        "head_repository" => request.repository,
        "base_branch" => request.base_branch,
        "base_repository" => request.repository,
        "title" => request.title, "body" => request.published_body
      }.merge(overrides)
    end
  end

  def test_github_gateway_uses_complete_all_state_inventory_and_exact_create_body
    Dir.mktmpdir do |repo|
      diff = ""
      request = Hive::GithubPublication::Request.new(
        worktree_path: repo,
        host: "github.com", repository: "acme/demo", base_branch: "main",
        creation_base_oid: "1" * 40, branch: "hive/patrol-fix/repair-one/g1",
        head_oid: "2" * 40, diff_digest: Digest::SHA256.hexdigest(diff),
        title: "Fix finding", body: "Exact body\n", diff: diff, draft: true
      )
      calls = []
      created_body = nil
      success = Object.new
      success.define_singleton_method(:success?) { true }
      transport = Object.new
      transport.define_singleton_method(:ensure_authenticated!) { |*_args, **_values| true }
      transport.define_singleton_method(:capture3) do |*args, **options|
        calls << [ args, options ]
        if args.include?("api")
          record = {
            "number" => 42, "html_url" => "https://github.com/acme/demo/pull/42",
            "state" => "closed", "merged_at" => "2026-08-20T12:00:00Z", "draft" => false,
            "title" => request.title, "body" => request.published_body,
            "head" => { "ref" => request.branch, "sha" => request.head_oid,
                        "repo" => { "full_name" => request.repository } },
            "base" => { "ref" => request.base_branch,
                        "repo" => { "full_name" => request.repository } }
          }
          [ JSON.generate([ [ record ] ]), "", success ]
        else
          body_index = args.index("--body-file")
          created_body = File.binread(args.fetch(body_index + 1))
          [ "https://github.com/acme/demo/pull/42\n", "", success ]
        end
      end
      gateway = Hive::GithubPublication::GithubGateway.new(transport: transport)

      assert gateway.authenticate!(host: request.host)
      records = gateway.list_pull_requests(
        repository: request.repository, host: request.host,
        branch: request.branch
      )
      assert_equal "MERGED", records.dig(0, "state")
      api_args, api_options = calls.first
      assert_includes api_args,
                      "repos/acme/demo/pulls?state=all&head=acme%3Ahive%2Fpatrol-fix%2Frepair-one%2Fg1&per_page=100"
      assert_includes api_args, "--paginate"
      assert_includes api_args, "--slurp"
      assert_equal Hive::GithubPublication::MAX_INVENTORY_BYTES,
                   api_options.fetch(:max_stdout_bytes)

      assert_equal true, gateway.create_pull_request(request: request)
      assert_equal request.published_body, created_body
      create_args = calls.last.first
      assert_includes create_args, "--draft"
      assert_includes create_args, "github.com/acme/demo"
      assert_includes create_args, request.branch
      assert_includes create_args, request.base_branch
    end
  end

  def test_git_gateway_reports_false_and_unverifiable_ancestry
    with_local_remote do |repo, remote, head|
      gateway = Hive::GithubPublication::GitGateway.new(
        remote: remote, allow_local_transport: true
      )
      base = capture("git", "-C", repo, "rev-parse", "HEAD~1").strip

      refute gateway.ancestor?(
        worktree_path: repo, ancestor_oid: head, head_oid: base
      )
      assert_raises(Hive::AgentGitGate::PublicationFailed) do
        gateway.ancestor?(
          worktree_path: repo, ancestor_oid: "f" * 40, head_oid: head
        )
      end

      expected = { "host" => "github.com", "repository" => "acme/demo" }
      calls = []
      resolver = lambda do |path, cfg:, managed:|
        calls << [ path, cfg, managed ]
        expected
      end
      with_replaced_singleton_method(Hive::Gh, :repository_identity, resolver) do
        assert_equal expected, gateway.repository_identity(worktree_path: repo)
      end
      assert_equal [ [ repo, nil, true ] ], calls
    end
  end

  def test_github_gateway_only_classifies_auth_rejection_as_definite
    with_local_remote do |repo, _remote, head|
      request = request_for(repo, head)
      transport = Object.new
      transport.define_singleton_method(:capture3) do |*, **|
        [ "", "failed", Hive::Gh::CommandStatus.new(exitstatus: 1) ]
      end
      gateway = Hive::GithubPublication::GithubGateway.new(transport: transport)
      error = assert_raises(Hive::GhError) do
        gateway.create_pull_request(request: request)
      end
      refute_kind_of Hive::GithubPublication::GithubGateway::DefiniteCreateFailure,
                     error

      transport.define_singleton_method(:capture3) do |*, **|
        [ "", "auth required", Hive::Gh::CommandStatus.new(exitstatus: 4) ]
      end
      assert_raises(
        Hive::GithubPublication::GithubGateway::DefiniteCreateFailure
      ) { gateway.create_pull_request(request: request) }
    end
  end

  def test_lost_create_response_reconciles_owned_match
    with_local_remote do |repo, remote, head|
      github = FakeGithub.new
      request = request_for(repo, head)
      github.records << github.owned_pr(request, number: 8, overrides: {
        "head_branch" => "another-branch", "body" => "user PR"
      })
      github.crash_after_create = true
      controller = controller_for(repo, remote, github)

      assert_raises(Hive::GithubPublication::Blocked) do
        controller.publish!(request, revalidate: ->(_phase) { true })
      end
      assert_equal 1, github.creates

      github.crash_after_create = false
      result = controller.publish!(request, revalidate: ->(_phase) { true })

      assert_equal 41, result.fetch("number")
      assert_equal "open", result.fetch("hosted_state")
      assert_equal head, remote_oid(remote, request.branch)
      assert_equal 1, github.creates
    end
  end

  def test_crash_after_push_converges_without_a_second_remote_mutation
    with_local_remote do |repo, remote, head|
      github = FakeGithub.new
      request = request_for(repo, head)
      git = Hive::GithubPublication::GitGateway.new(
        remote: remote, allow_local_transport: true
      )
      pushes = 0
      crashing_git = Object.new
      crashing_git.define_singleton_method(:observe) { |**values| git.observe(**values) }
      crashing_git.define_singleton_method(:push_exact) do |**values|
        pushes += 1
        receipt = git.push_exact(**values)
        raise Hive::AgentGitGate::PublicationFailed, "lost push response" if pushes == 1
        receipt
      end
      controller = Hive::GithubPublication::Controller.new(
        state_path: state_path(repo), git_gateway: crashing_git,
        github_gateway: github
      )

      result = controller.publish!(request, revalidate: ->(_phase) { true })

      assert_equal 1, pushes
      assert_equal head, result.fetch("head_oid")
      assert_equal 1, github.creates
    end
  end

  def test_intents_retry_only_when_remote_absence_or_a_definite_failure_proves_safety
    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      github = FakeGithub.new
      git = CountingGit.new(remote)
      controller = controller_for(repo, remote, github, git_gateway: git)
      first_push_gate = true
      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller.publish!(request, revalidate: lambda do |phase|
          next true unless phase == :before_push && first_push_gate
          first_push_gate = false
          false
        end)
      end
      assert_equal "stale_authority", error.code
      assert_equal 0, git.pushes

      first_create_gate = true
      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller.publish!(request, revalidate: lambda do |phase|
          next true unless phase == :before_create && first_create_gate
          first_create_gate = false
          false
        end)
      end
      assert_equal "stale_authority", error.code
      assert_equal 1, git.pushes
      assert_equal 0, github.creates

      result = controller.publish!(request, revalidate: ->(_phase) { true })
      assert_equal request.head_oid, result.fetch("head_oid")
      assert_equal 1, git.pushes
      assert_equal 1, github.creates
    end

    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      github = FakeGithub.new
      delegate = CountingGit.new(remote)
      attempts = 0
      lost_git = Object.new
      lost_git.define_singleton_method(:observe) { |**values| delegate.observe(**values) }
      lost_git.define_singleton_method(:push_exact) do |**_values|
        attempts += 1
        raise Hive::AgentGitGate::PublicationFailed, "unknown outcome"
      end
      controller = controller_for(repo, remote, github, git_gateway: lost_git)
      2.times do
        error = assert_raises(Hive::GithubPublication::Blocked) do
          controller.publish!(request, revalidate: ->(_phase) { true })
        end
        assert_equal "push_failed", error.code
      end
      assert_equal 2, attempts
      assert_equal 0, github.creates
    end

    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      github = FakeGithub.new
      github.fail_before_create = true
      controller = controller_for(repo, remote, github)
      2.times do
        error = assert_raises(Hive::GithubPublication::Blocked) do
          controller.publish!(request, revalidate: ->(_phase) { true })
        end
        assert_equal "create_outcome_unknown", error.code
      end
      assert_equal 1, github.creates
    end

    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      github = FakeGithub.new
      github.definite_fail_before_create = true
      controller = controller_for(repo, remote, github)
      2.times do
        error = assert_raises(Hive::GithubPublication::Blocked) do
          controller.publish!(request, revalidate: ->(_phase) { true })
        end
        assert_equal "create_failed", error.code
      end
      assert_equal 2, github.creates
      github.definite_fail_before_create = false
      assert_equal request.head_oid,
                   controller.publish!(request, revalidate: ->(_phase) { true }).fetch("head_oid")
      assert_equal 3, github.creates
    end
  end

  def test_exact_existing_owned_pr_in_any_hosted_state_is_adopted_without_mutation
    %w[OPEN CLOSED MERGED].each do |state|
      with_local_remote do |repo, remote, head|
        request = request_for(repo, head)
        github = FakeGithub.new
        github.records << github.owned_pr(
          request, state: state, draft: state == "OPEN"
        )
        git = CountingGit.new(remote)

        result = controller_for(repo, remote, github, git_gateway: git)
          .publish!(request, revalidate: ->(_phase) { true })

        expected = state == "OPEN" ? "draft" : state.downcase
        assert_equal expected, result.fetch("hosted_state")
        assert_equal 0, git.pushes
        assert_equal 0, github.creates
      end
    end
  end

  def test_controller_owned_draft_accepts_only_a_fast_forward_revision
    with_local_remote do |repo, remote, head|
      github = FakeGithub.new
      git = CountingGit.new(remote)
      controller = controller_for(repo, remote, github, git_gateway: git)
      original = request_for(repo, head)

      published = controller.publish!(original, revalidate: ->(_phase) { true })
      original_state = File.binread(state_path(repo))
      assert_equal head, published.fetch("head_oid")

      revised_head = commit(repo, "follow-up.txt", "follow-up\n", "follow-up")
      revised = revised_request(repo, original, revised_head)
      publication = controller.publish!(revised, revalidate: ->(_phase) { true })

      assert_equal revised_head, publication.fetch("head_oid")
      assert_equal original.publication_id, publication.fetch("publication_id")
      assert_equal revised_head, remote_oid(remote, revised.branch)
      assert_equal 2, git.pushes
      assert_equal 1, github.creates
      assert_equal original_state, File.binread(state_path(repo)),
                   "the first exact publication remains the immutable ownership anchor"

      github.records.first["head_oid"] = revised_head
      replay = controller.publish!(revised, revalidate: ->(_phase) { true })
      assert_equal revised_head, replay.fetch("head_oid")
      assert_equal 2, git.pushes
      assert_equal 1, github.creates

      phases = []
      github.records.first["state"] = "MERGED"
      merged = controller.publish!(revised, revalidate: ->(phase) { phases << phase; true })
      assert_equal "merged", merged.fetch("hosted_state")
      assert_equal revised_head, merged.fetch("head_oid")
      assert_equal [ :final ], phases
    end
  end

  def test_controller_owned_draft_refuses_a_non_fast_forward_revision
    with_local_remote do |repo, remote, head|
      github = FakeGithub.new
      controller = controller_for(repo, remote, github)
      original = request_for(repo, head)
      controller.publish!(original, revalidate: ->(_phase) { true })

      revised_head = commit(repo, "follow-up.txt", "follow-up\n", "follow-up")
      revised = revised_request(repo, original, revised_head)
      git = CountingGit.new(remote)
      ancestry = [ true, false ]
      git.define_singleton_method(:ancestor?) { |**| ancestry.shift }

      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller_for(repo, remote, github, git_gateway: git)
          .publish!(revised, revalidate: ->(_phase) { true })
      end
      assert_equal "revision_non_fast_forward", error.code
      assert_equal head, remote_oid(remote, revised.branch)
      assert_equal 0, git.pushes
      assert_equal 1, github.creates
    end
  end

  def test_revision_reconciliation_fails_closed_for_identity_remote_terminal_and_ancestry_conflicts
    with_published_revision do |_repo, _remote, original, revised, controller, github|
      github.records.first["body"] = "edited by somebody else"
      assert_revision_error("revision_identity_conflict", controller, revised)
    end

    with_published_revision do |_repo, _remote, _original, revised, controller, _github|
      controller.instance_variable_set(
        :@git, sequence_git([ remote_observation("f" * 40) ])
      )
      assert_revision_error("revision_remote_conflict", controller, revised)
    end

    with_published_revision do |_repo, _remote, _original, revised, controller, github|
      github.records.first["head_oid"] = "f" * 40
      controller.instance_variable_set(
        :@git, sequence_git([ remote_observation("f" * 40) ], ancestor: false)
      )
      assert_revision_error("revision_history_rewritten", controller, revised)
    end

    with_published_revision do |_repo, _remote, _original, revised, controller, github|
      github.records.first["state"] = "MERGED"
      assert_revision_error("revision_hosted_terminal", controller, revised)
    end

    with_published_revision do |_repo, _remote, original, revised, controller, _github|
      controller.instance_variable_set(
        :@git,
        sequence_git([ remote_observation(original.head_oid) ], ancestor: :error)
      )
      assert_revision_error("revision_ancestry_unavailable", controller, revised)
    end
  end

  def test_revision_push_reconciles_lost_responses_and_blocks_unknown_outcomes
    with_published_revision do |_repo, _remote, original, revised, controller, _github|
      controller.instance_variable_set(
        :@git, sequence_git([ remote_observation(original.head_oid) ], push: {})
      )
      assert_revision_error("revision_push_outcome_unknown", controller, revised)
    end

    with_published_revision do |_repo, _remote, original, revised, controller, _github|
      controller.instance_variable_set(
        :@git,
        sequence_git(
          [ remote_observation(original.head_oid), remote_observation(original.head_oid) ],
          push_error: true
        )
      )
      assert_revision_error("revision_push_outcome_unknown", controller, revised)
    end

    with_published_revision do |_repo, _remote, original, revised, controller, _github|
      controller.instance_variable_set(
        :@git,
        sequence_git(
          [ remote_observation(original.head_oid), remote_observation(original.head_oid) ],
          push: revision_push_observation(original, revised)
        )
      )
      assert_revision_error("revision_push_not_observed", controller, revised)
    end

    with_published_revision do |_repo, _remote, original, revised, controller, _github|
      controller.instance_variable_set(
        :@git,
        sequence_git(
          [
            remote_observation(original.head_oid),
            remote_observation(revised.head_oid),
            remote_observation(revised.head_oid)
          ],
          push_error: true
        )
      )
      publication = controller.publish!(revised, revalidate: ->(*) { true })
      assert_equal revised.head_oid, publication.fetch("head_oid")
    end
  end

  def test_preexisting_branch_without_exact_owned_pr_is_never_adopted_or_replaced
    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      [ [ "same", head ], [ "wrong", request.creation_base_oid ] ].each do |label, remote_head|
        capture(
          "git", "-C", repo, "push", remote,
          "#{remote_head}:refs/heads/#{request.branch}", "--force"
        )
        git = CountingGit.new(remote)
        github = FakeGithub.new
        error = assert_raises(Hive::GithubPublication::Blocked) do
          controller_for(repo, remote, github, git_gateway: git, state_suffix: label)
            .publish!(request, revalidate: ->(_phase) { true })
        end
        expected = label == "same" ? "remote_branch_unowned" : "remote_branch_conflict"
        assert_equal expected, error.code
        assert_equal 0, git.pushes
        assert_equal 0, github.creates
        assert_equal remote_head, remote_oid(remote, request.branch)
      end
    end
  end

  def test_foreign_wrong_identity_and_multiple_owned_candidates_block
    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      variants = [
        [ "foreign", [ FakeGithub.new.owned_pr(request, overrides: { "body" => "user PR" }) ] ],
        [ "wrong_head", [ FakeGithub.new.owned_pr(request, overrides: { "head_oid" => "f" * 40 }) ] ],
        [ "wrong_base", [ FakeGithub.new.owned_pr(request, overrides: { "base_branch" => "release" }) ] ],
        [ "wrong_title", [ FakeGithub.new.owned_pr(request, overrides: { "title" => "Edited title" }) ] ],
        [ "wrong_body", [ FakeGithub.new.owned_pr(request, overrides: { "body" => "Edited\n\n#{request.marker}\n" }) ] ],
        [ "multiple", [ FakeGithub.new.owned_pr(request, number: 1), FakeGithub.new.owned_pr(request, number: 2) ] ]
      ]

      variants.each do |label, records|
        github = FakeGithub.new(records: records)
        error = assert_raises(Hive::GithubPublication::Blocked, label) do
          controller_for(repo, remote, github, state_suffix: label)
            .publish!(request, revalidate: ->(_phase) { true })
        end
        assert_includes error.message, "pull-request identity conflict"
        assert_equal 0, github.creates
      end
    end
  end

  def test_partial_or_failed_inventory_is_never_treated_as_absence
    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      [ :invalid_inventory, :list_error ].each do |failure|
        github = FakeGithub.new
        github.public_send("#{failure}=", true)
        error = assert_raises(Hive::GithubPublication::Blocked) do
          controller_for(repo, remote, github, state_suffix: failure)
            .publish!(request, revalidate: ->(_phase) { true })
        end
        assert_match(/inventory/, error.message)
        refute_includes error.message, "sensitive-looking"
        assert_equal 0, github.creates
      end
    end

    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      github = FakeGithub.new(
        records: Array.new(Hive::GithubPublication::MAX_RECORDS + 1, {})
      )
      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller_for(repo, remote, github)
          .publish!(request, revalidate: ->(_phase) { true })
      end
      assert_equal "inventory_capped", error.code
      assert_equal 0, github.creates
    end

    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      duplicate = FakeGithub.new.owned_pr(
        request, number: 9,
        overrides: { "head_branch" => "unrelated", "body" => "user PR" }
      )
      github = FakeGithub.new(records: [ duplicate, duplicate.dup ])
      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller_for(repo, remote, github)
          .publish!(request, revalidate: ->(_phase) { true })
      end
      assert_equal "inventory_incomplete", error.code
      assert_equal 0, github.creates
    end
  end

  def test_pr_observation_must_still_be_exact_before_final_receipt
    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      github = FakeGithub.new
      controller = controller_for(repo, remote, github)
      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller.publish!(request, revalidate: ->(phase) { phase != :final })
      end
      assert_equal "stale_authority", error.code
      assert_equal 1, github.creates

      github.records.clear
      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller.publish!(request, revalidate: ->(_phase) { true })
      end
      assert_equal "pr_observation_missing", error.code
      assert_equal 1, github.creates
    end
  end

  def test_secret_scan_covers_title_body_and_exact_diff_without_persisting_bytes
    with_local_remote do |repo, remote, head|
      clean = request_for(repo, head)
      secret = "ghp_#{'a' * 36}"
      variants = {
        "title" => clean.to_h.merge(title: "Fix #{secret}"),
        "body" => clean.to_h.merge(body: "Details #{secret}"),
        "diff" => clean.to_h.merge(diff: "patch #{secret}").tap do |values|
          values[:diff_digest] = Digest::SHA256.hexdigest(values.fetch(:diff))
        end
      }
      variants.each do |label, values|
        request = Hive::GithubPublication::Request.new(**values)
        git = CountingGit.new(remote)
        path = state_path(repo).sub(/\.json\z/, "-secret-#{label}.json")
        error = assert_raises(Hive::GithubPublication::Blocked) do
          Hive::GithubPublication::Controller.new(
            state_path: path, git_gateway: git, github_gateway: FakeGithub.new
          ).publish!(request, revalidate: ->(_phase) { true })
        end
        assert_equal "secret_detected", error.code
        refute_includes error.message, secret
        refute File.exist?(path)
        assert_equal 0, git.pushes
      end
    end
  end

  def test_creation_base_is_immutable_even_when_the_base_branch_later_advances
    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      github = FakeGithub.new
      github.crash_after_create = true
      controller = controller_for(repo, remote, github)
      assert_raises(Hive::GithubPublication::Blocked) do
        controller.publish!(request, revalidate: ->(_phase) { true })
      end

      commit(repo, "later.txt", "later\n", "advance main")
      capture("git", "-C", repo, "push", remote, "HEAD:refs/heads/main")
      github.crash_after_create = false
      result = controller.publish!(request, revalidate: ->(_phase) { true })

      assert_equal request.creation_base_oid, result.fetch("creation_base_oid")
      assert_equal 1, github.creates
    end
  end

  def test_request_rejects_mismatched_bytes_non_boolean_draft_and_unbounded_text
    with_local_remote do |repo, _remote, head|
      valid = request_for(repo, head).to_h
      invalid = [
        valid.merge(diff_digest: "0" * 64),
        valid.merge(draft: "yes"),
        valid.merge(worktree_path: "bad\npath"),
        valid.merge(title: "bad\ncontrol")
      ]
      invalid.each do |values|
        assert_raises(ArgumentError) { Hive::GithubPublication::Request.new(**values) }
      end
    end
  end

  def test_github_gateway_rejects_incomplete_unparseable_and_invalid_inventory
    responses = []
    transport = Object.new
    transport.define_singleton_method(:capture3) { |*, **| responses.shift }
    gateway = Hive::GithubPublication::GithubGateway.new(transport: transport)
    failure = Hive::Gh::CommandStatus.new(exitstatus: 1)
    success = Hive::Gh::CommandStatus.new(exitstatus: 0)

    responses << [ "fallback error", "", failure ]
    assert_raises(Hive::GhError) do
      gateway.list_pull_requests(repository: "acme/demo", host: "github.com", branch: "topic")
    end
    responses << [ "{}", "", success ]
    assert_raises(Hive::GhError) do
      gateway.list_pull_requests(repository: "acme/demo", host: "github.com", branch: "topic")
    end
    responses << [ "{", "", success ]
    assert_raises(Hive::GhError) do
      gateway.list_pull_requests(repository: "acme/demo", host: "github.com", branch: "topic")
    end

    raw = raw_pull_request
    invalid = [
      nil,
      raw.reject { |key, _| key == "head" },
      raw.merge("state" => "unknown"),
      raw.merge("html_url" => "https://github.com/other/demo/pull/42"),
      raw.merge("html_url" => "https://%")
    ]
    invalid.each do |record|
      assert_raises(Hive::GhError) do
        gateway.send(:normalize_record, record, "acme/demo", "github.com")
      end
    end

    responses << [ JSON.generate([ Array.new(Hive::GithubPublication::MAX_RECORDS + 1, raw) ]), "", success ]
    assert_raises(Hive::GhError) do
      gateway.list_pull_requests(repository: "acme/demo", host: "github.com", branch: "topic")
    end

    with_local_remote do |repo, _remote, head|
      request = request_for(repo, head)
      responses << [ "create rejected", "", failure ]
      assert_raises(Hive::GhError) { gateway.create_pull_request(request: request) }
    end
  end

  def test_controller_rejects_malformed_inventory_observations_and_state_relations
    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      controller = controller_for(repo, remote, FakeGithub.new)
      base = prepared_state(controller, request)
      push = push_observation(request)
      pr = pr_observation(controller, request)

      invalid_states = [
        base.merge("phase" => "unknown"),
        base.merge("updated_at" => "bad"),
        base.merge("phase" => "branch_observed"),
        base.merge("create_attempts" => 1),
        base.merge("phase" => "pr_create_intent", "push_observation" => push, "pr" => {}),
        base.merge("phase" => "pr_observed", "pr" => nil),
        base.merge("push_attempted_at" => "2026-08-20T12:00:00Z"),
        base.merge("phase" => "branch_observed", "push_observation" => push),
        base.merge(
          "phase" => "pr_observed", "pr" => pr, "create_attempts" => 1,
          "create_attempted_at" => "2026-08-20T12:00:00Z"
        )
      ]
      invalid_states.each do |state|
        assert_raises(Hive::GithubPublication::Blocked) do
          controller.send(:validate_state, state)
        end
      end

      record = FakeGithub.new.owned_pr(request)
      invalid_records = [
        nil,
        record.merge("head_branch" => nil),
        record.merge("head_repository" => 7),
        record.merge("head_oid" => "bad"),
        record.merge("url" => "https://github.com/other/demo/pull/42"),
        record.merge("url" => "https://%")
      ]
      invalid_records.each do |candidate|
        assert_raises(Hive::GithubPublication::Blocked) do
          controller.send(:validate_record!, candidate, request)
        end
      end

      controller.instance_variable_set(:@git, Object.new.tap do |git|
        git.define_singleton_method(:observe) { |**| {} }
      end)
      assert_raises(Hive::GithubPublication::Blocked) { controller.send(:observe, request) }
      controller.instance_variable_set(:@git, Object.new.tap do |git|
        git.define_singleton_method(:observe) { |**| raise "offline" }
      end)
      assert_raises(Hive::GithubPublication::Blocked) { controller.send(:observe, request) }

      assert_raises(Hive::GithubPublication::Blocked) do
        controller.send(:validate_push_receipt!, {}, nil, request)
      end
      bad_pr = pr.merge("observed_at" => "bad")
      refute controller.send(:valid_pr_observation?, bad_pr, base.merge("phase" => "pr_observed"))

      FileUtils.mkdir_p(File.dirname(state_path(repo)))
      File.write(state_path(repo), "{")
      assert_raises(Hive::GithubPublication::Blocked) { controller.send(:read_state) }
    end
  end

  def test_controller_covers_remote_reconciliation_failure_outcomes
    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      controller = controller_for(repo, remote, FakeGithub.new)
      state = prepared_state(controller, request).merge(
        "push_attempted_at" => "2026-08-20T12:00:00Z"
      )
      controller.instance_variable_set(:@git, sequence_git(
        [ remote_observation(request.head_oid) ]
      ))
      observed = controller.send(:reconcile_push, request, state, ->(*) { true })
      assert_equal "branch_observed", observed.fetch("phase")

      retry_state = prepared_state(controller, request).merge(
        "phase" => "push_intent", "push_attempted_at" => "2026-08-20T12:00:00Z"
      )
      controller.instance_variable_set(:@git, sequence_git(
        [ remote_observation(nil), remote_observation(request.head_oid) ],
        push: push_observation(request)
      ))
      assert_equal "branch_observed",
                   controller.send(:reconcile_push, request, retry_state, ->(*) { true }).fetch("phase")

      controller.instance_variable_set(:@git, sequence_git(
        [ remote_observation(nil) ], push: {}
      ))
      assert_raises(Hive::GithubPublication::Blocked) do
        controller.send(:reconcile_push, request, prepared_state(controller, request), ->(*) { true })
      end

      controller.instance_variable_set(:@git, sequence_git(
        [ remote_observation(nil), remote_observation("f" * 40) ], push_error: true
      ))
      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller.send(:reconcile_push, request, prepared_state(controller, request), ->(*) { true })
      end
      assert_equal "push_outcome_unknown", error.code

      controller.instance_variable_set(:@git, sequence_git(
        [ remote_observation(nil), remote_observation(nil) ], push: push_observation(request)
      ))
      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller.send(:reconcile_push, request, prepared_state(controller, request), ->(*) { true })
      end
      assert_equal "push_not_observed", error.code

      controller.instance_variable_set(:@git, sequence_git([ remote_observation("f" * 40) ]))
      branch_state = prepared_state(controller, request).merge(
        "phase" => "branch_observed", "push_attempted_at" => "2026-08-20T12:00:00Z",
        "push_observation" => push_observation(request)
      )
      assert_raises(Hive::GithubPublication::Blocked) do
        controller.send(:reconcile_create, request, branch_state, ->(*) { true })
      end

      github = FakeGithub.new
      github.define_singleton_method(:create_pull_request) { |**| true }
      controller.instance_variable_set(:@github, github)
      controller.instance_variable_set(:@git, sequence_git([ remote_observation(request.head_oid) ]))
      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller.send(:reconcile_create, request, branch_state, ->(*) { true })
      end
      assert_equal "create_not_observed", error.code
    end
  end

  def test_controller_rejects_invalid_entrypoints_unsafe_state_and_unknown_phase
    with_local_remote do |repo, remote, head|
      request = request_for(repo, head)
      controller = controller_for(repo, remote, FakeGithub.new)
      assert_raises(ArgumentError) { controller.publish!(nil, revalidate: nil) }

      unsafe = Object.new
      unsafe.define_singleton_method(:with_lock) do |*|
        raise Hive::ManagedDirectory::UnsafeError, "unsafe"
      end
      controller.instance_variable_set(:@directory, unsafe)
      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller.publish!(request, revalidate: ->(*) { true })
      end
      assert_equal "unsafe_state", error.code

      github = FakeGithub.new
      github.define_singleton_method(:authenticate!) { |**| raise "no auth" }
      controller = controller_for(repo, remote, github)
      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller.publish!(request, revalidate: ->(*) { true })
      end
      assert_equal "authentication_unavailable", error.code

      controller = controller_for(repo, remote, FakeGithub.new)
      controller.define_singleton_method(:validate_request!) { |*| true }
      controller.define_singleton_method(:reconcile_pull_requests) { |*| nil }
      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller.send(:reconcile, request, { "phase" => "unknown" }, ->(*) { true })
      end
      assert_equal "invalid_phase", error.code

      error = assert_raises(Hive::GithubPublication::Blocked) do
        controller.send(:revalidate!, ->(*) { raise "failed" }, :final)
      end
      assert_equal "stale_authority", error.code
    end
  end

  private

  class CountingGit
    attr_reader :pushes

    def initialize(remote)
      @delegate = Hive::GithubPublication::GitGateway.new(
        remote: remote, allow_local_transport: true
      )
      @pushes = 0
    end

    def observe(**values) = @delegate.observe(**values)
    def ancestor?(**values) = @delegate.ancestor?(**values)

    def push_exact(**values)
      @pushes += 1
      @delegate.push_exact(**values)
    end
  end

  def controller_for(repo, remote, github, git_gateway: nil, state_suffix: nil)
    path = state_path(repo)
    path = path.sub(/\.json\z/, "-#{state_suffix}.json") if state_suffix
    Hive::GithubPublication::Controller.new(
      state_path: path,
      git_gateway: git_gateway || Hive::GithubPublication::GitGateway.new(
        remote: remote, allow_local_transport: true
      ),
      github_gateway: github
    )
  end

  def state_path(repo)
    File.join(repo, ".hive-state", "publication.json")
  end

  def request_for(repo, head)
    diff = capture("git", "-C", repo, "diff", "HEAD~1..HEAD")
    Hive::GithubPublication::Request.new(
      worktree_path: repo,
      host: "github.com", repository: "acme/demo", base_branch: "main",
      creation_base_oid: capture("git", "-C", repo, "rev-parse", "HEAD~1").strip,
      branch: "hive/patrol-fix/repair-one/g1", head_oid: head,
      diff_digest: Digest::SHA256.hexdigest(diff), title: "Fix the patrol finding",
      body: "## Fix\n\nValidated exact patch.\n", diff: diff, draft: true
    )
  end

  def revised_request(repo, original, head)
    diff = capture(
      "git", "-C", repo, "diff", "#{original.creation_base_oid}..#{head}"
    )
    Hive::GithubPublication::Request.new(
      **original.to_h.merge(
        head_oid: head,
        diff: diff,
        diff_digest: Digest::SHA256.hexdigest(diff)
      )
    )
  end

  def raw_pull_request
    {
      "number" => 42, "html_url" => "https://github.com/acme/demo/pull/42",
      "state" => "open", "merged_at" => nil, "draft" => false,
      "title" => "Title", "body" => "Body",
      "head" => {
        "ref" => "topic", "sha" => "2" * 40,
        "repo" => { "full_name" => "acme/demo" }
      },
      "base" => {
        "ref" => "main", "repo" => { "full_name" => "acme/demo" }
      }
    }
  end

  def prepared_state(controller, request)
    controller.send(:identity, request).merge(
      "schema" => Hive::GithubPublication::SCHEMA,
      "schema_version" => Hive::GithubPublication::SCHEMA_VERSION,
      "phase" => "prepared", "expected_remote_oid" => nil,
      "push_attempted_at" => nil, "push_observation" => nil,
      "create_attempts" => 0, "create_attempted_at" => nil, "pr" => nil,
      "updated_at" => "2026-08-20T12:00:00Z"
    )
  end

  def remote_observation(oid)
    { "oid" => oid, "remote_fingerprint" => "9" * 64 }
  end

  def push_observation(request)
    {
      "expected_oid" => nil, "before_oid" => nil,
      "after_oid" => request.head_oid, "remote_fingerprint" => "9" * 64
    }
  end

  def pr_observation(controller, request)
    controller.send(:identity, request).except("draft").merge(
      "number" => 42, "url" => "https://github.com/acme/demo/pull/42",
      "hosted_state" => "open", "observed_at" => "2026-08-20T12:00:00Z"
    )
  end

  def sequence_git(observations, push: nil, push_error: false, ancestor: true)
    Object.new.tap do |git|
      git.define_singleton_method(:observe) { |**| observations.shift || raise("unexpected observation") }
      git.define_singleton_method(:ancestor?) do |**|
        raise "ancestry failed" if ancestor == :error

        ancestor
      end
      git.define_singleton_method(:push_exact) do |**|
        raise "push failed" if push_error
        push
      end
    end
  end

  def revision_push_observation(original, revised)
    {
      "expected_oid" => original.head_oid,
      "before_oid" => original.head_oid,
      "after_oid" => revised.head_oid,
      "remote_fingerprint" => "9" * 64
    }
  end

  def with_published_revision
    with_local_remote do |repo, remote, head|
      github = FakeGithub.new
      controller = controller_for(repo, remote, github)
      original = request_for(repo, head)
      controller.publish!(original, revalidate: ->(*) { true })
      revised_head = commit(repo, "follow-up.txt", "follow-up\n", "follow-up")
      revised = revised_request(repo, original, revised_head)
      yield repo, remote, original, revised, controller, github
    end
  end

  def assert_revision_error(code, controller, request)
    error = assert_raises(Hive::GithubPublication::Blocked) do
      controller.publish!(request, revalidate: ->(*) { true })
    end
    assert_equal code, error.code
  end

  def with_local_remote
    Dir.mktmpdir do |dir|
      remote = File.join(dir, "remote.git")
      repo = File.join(dir, "repo")
      capture("git", "init", "--bare", remote)
      capture("git", "init", "-b", "main", repo)
      capture("git", "-C", repo, "config", "user.email", "test@example.com")
      capture("git", "-C", repo, "config", "user.name", "Test")
      File.write(File.join(repo, "base.txt"), "base\n")
      capture("git", "-C", repo, "add", "base.txt")
      capture("git", "-C", repo, "commit", "-m", "base")
      capture("git", "-C", repo, "remote", "add", "origin", remote)
      capture("git", "-C", repo, "push", "origin", "main")
      head = commit(repo, "fix.txt", "fix\n", "fix")
      yield repo, remote, head
    end
  end

  def commit(repo, path, body, message)
    File.write(File.join(repo, path), body)
    capture("git", "-C", repo, "add", path)
    capture("git", "-C", repo, "commit", "-m", message)
    capture("git", "-C", repo, "rev-parse", "HEAD").strip
  end

  def remote_oid(remote, branch)
    out = capture("git", "ls-remote", remote, "refs/heads/#{branch}")
    out.split.first
  end

  def capture(*args)
    out, err, status = Open3.capture3(*args)
    raise "#{args.join(' ')}: #{err}" unless status.success?
    out
  end
end
