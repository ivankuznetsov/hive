require "test_helper"
require "hive/config"
require "hive/refactor_patrol/fixer"
require "hive/refactor_patrol/pr_opener"
require "hive/refactor_patrol/thesis"

class RefactorPatrolPrOpenerTest < Minitest::Test
  include HiveTestHelper

  class FakeGh
    attr_accessor :prs, :create_failure, :create_output, :remote_oid, :repository,
                  :verification_error, :before_remote_read
    attr_reader :pushed, :created, :bodies, :authenticated_hosts, :lookups,
                :verified

    def initialize
      @prs = []
      @pushed = []
      @created = []
      @bodies = []
      @authenticated_hosts = []
      @lookups = []
      @verified = []
      @create_output = "https://github.com/acme/demo/pull/9\n"
      @repository = { "repository" => "acme/demo", "host" => "github.com" }
    end

    def ensure_authenticated!(_cfg, host:)
      @authenticated_hosts << host
      true
    end

    def lookup_prs_for_branch(path, branch, repository:, host:, cfg:)
      @lookups << { path: path, branch: branch, repository: repository, host: host }
      @prs
    end

    def origin_push_url(_path, cfg:)
      "git@github.com:acme/demo.git"
    end

    def repository_identity_from_remote(_remote_url)
      @repository
    end

    def remote_branch_oid(_path, _branch, cfg:, remote:)
      @before_remote_read&.call
      @remote_oid
    end

    def push_branch!(path, branch, cfg:, expected_remote_oid: nil,
                     expected_remote_absent: false, remote:, set_upstream:)
      @pushed << [
        path, branch, expected_remote_oid, expected_remote_absent, remote, set_upstream
      ]
      @remote_oid = Open3.capture3("git", "-C", path, "rev-parse", branch).first.strip
    end

    def verify_pr_identity!(pr_url, **arguments)
      @verified << arguments.merge(pr_url: pr_url)
      raise Hive::GhError, @verification_error if @verification_error

      true
    end

    def capture3(*args, chdir:, cfg:)
      @created << args
      body_index = args.index("--body-file")
      @bodies << File.binread(args.fetch(body_index + 1)) if body_index
      if @create_failure
        return [ "", @create_failure, Hive::Gh::CommandStatus.new(exitstatus: 1) ]
      end

      [ @create_output, "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
    end
  end

  class Handoff
    attr_reader :calls

    def initialize(result: "/tmp/review-task")
      @result = result
      @calls = []
    end

    def enqueue(**args)
      @calls << args
      @result
    end
  end

  def test_create_persists_intent_uses_explicit_repo_and_requires_review_handoff
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      handoff = Handoff.new
      intents = 0
      result = opener(repo, gh, handoff).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { intents += 1; true }
      )

      assert_equal "pr_opened", result.outcome
      assert result.terminal
      assert_equal 2, intents, "push and PR create require distinct durable intents"
      assert_equal(
        [ [ repo, "master", nil, true, "git@github.com:acme/demo.git", false ] ],
        gh.pushed
      )
      assert_includes gh.created.first, "--repo"
      assert_includes gh.created.first, "github.com/acme/demo"
      assert_includes gh.bodies.first, "<!-- hive-refactor-patrol action=fix-fp"
      assert_equal true, handoff.calls.first.fetch(:mandatory)
      context = handoff.calls.first.fetch(:context)
      assert_equal thesis.to_h, context.fetch("thesis")
      assert_equal source, context.fetch("source_pr")
      assert_equal "job-7", context.fetch("job_id")
      assert_equal "fix-fp", context.fetch("canonical_action_id")
      assert_equal patch(repo).commit_sha, context.dig("patch", "commit_sha")
      assert_equal "/tmp/review-task", result.review_task_path
      assert_equal(
        {
          "pr_url" => "https://github.com/acme/demo/pull/9",
          "review_task_path" => "/tmp/review-task"
        },
        result.receipts
      )
    end
  end

  def test_push_is_fenced_and_rebased_branch_uses_exact_remote_oid_lease
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      gh.remote_oid = "a" * 40
      fences = 0

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        superseded_patch_commits: [ "a" * 40 ],
        authorize_push: -> { fences += 1; true },
        record_intent: -> { true }
      )

      assert_equal "pr_opened", result.outcome
      assert_equal 2, fences
      assert_equal(
        [ [ repo, "master", "a" * 40, false, "git@github.com:acme/demo.git", false ] ],
        gh.pushed
      )
    end
  end

  def test_arbitrary_existing_remote_branch_is_a_retryable_conflict
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      gh.remote_oid = "a" * 40
      fences = 0

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        authorize_push: -> { fences += 1; true },
        record_intent: -> { flunk "must not persist create intent" }
      )

      assert_equal "remote_branch_conflict", result.outcome
      refute result.terminal
      assert_equal 0, fences
      assert_empty result.receipts
      assert_empty gh.pushed
      assert_empty gh.created
    end
  end

  def test_existing_remote_branch_at_the_exact_patch_commit_needs_no_replacement_proof
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      gh.remote_oid = local_patch.commit_sha

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { true }
      )

      assert_equal "pr_opened", result.outcome
      assert result.terminal
      assert_empty gh.pushed
      assert_equal 1, gh.created.size
    end
  end

  def test_trunk_drift_result_does_not_duplicate_versioned_patch_metadata
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = isolated_patch(repo)
      File.write(File.join(repo, "README.md"), "trunk advanced\n")
      run!("git", "-C", repo, "add", "README.md")
      run!("git", "-C", repo, "commit", "-m", "advance trunk", "--quiet")

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { flunk "must not persist create intent" }
      )

      assert_equal "trunk_drift_retry", result.outcome
      refute result.terminal
      assert_empty result.receipts
      assert_empty gh.pushed
      assert_empty gh.created
    ensure
      FileUtils.rm_rf(local_patch&.worktree_path)
    end
  end

  def test_persisted_push_completion_still_revalidates_trunk_before_pr_create
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = isolated_patch(repo)
      state = {
        "push_intent" => Hive::RefactorPatrol::PrOpener.push_intent_payload(
          canonical_action_id: "fix-fp", repository: "acme/demo",
          branch: local_patch.branch, commit_sha: local_patch.commit_sha,
          expected_remote_oid: nil
        ),
        "push_complete" => Hive::RefactorPatrol::PrOpener.push_complete_payload(
          canonical_action_id: "fix-fp", repository: "acme/demo",
          branch: local_patch.branch, commit_sha: local_patch.commit_sha
        )
      }
      gh.remote_oid = local_patch.commit_sha
      File.write(File.join(repo, "README.md"), "trunk advanced after push\n")
      run!("git", "-C", repo, "add", "README.md")
      run!("git", "-C", repo, "commit", "-m", "advance after push", "--quiet")
      observed = run!("git", "-C", repo, "rev-parse", "HEAD").strip

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        publication_state: state,
        record_intent: -> { flunk "stale pushed patch must not begin PR creation" }
      )

      assert_equal "trunk_drift_retry", result.outcome
      assert_equal observed, result.observed_head_sha
      assert_empty gh.pushed
      assert_empty gh.created
    ensure
      FileUtils.rm_rf(local_patch&.worktree_path)
    end
  end

  def test_landed_push_is_receipted_before_a_drifted_attempt_is_superseded
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = isolated_patch(repo)
      push_intent = Hive::RefactorPatrol::PrOpener.push_intent_payload(
        canonical_action_id: "fix-fp", repository: "acme/demo",
        branch: local_patch.branch, commit_sha: local_patch.commit_sha,
        expected_remote_oid: nil
      )
      gh.remote_oid = local_patch.commit_sha
      File.write(File.join(repo, "README.md"), "trunk advanced after unreceipted push\n")
      run!("git", "-C", repo, "add", "README.md")
      run!("git", "-C", repo, "commit", "-m", "advance after remote push", "--quiet")
      observed = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      phases = []

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        publication_state: { "push_intent" => push_intent },
        record_intent: ->(phase:, payload:) { phases << [ phase, payload ]; true }
      )

      assert_equal "trunk_drift_retry", result.outcome
      assert_equal observed, result.observed_head_sha
      assert_equal [ "push_complete" ], phases.map(&:first)
      assert_equal local_patch.commit_sha, phases.first.last.fetch("remote_oid")
      assert_empty gh.pushed
      assert_empty gh.created
    ensure
      FileUtils.rm_rf(local_patch&.worktree_path)
    end
  end

  def test_completed_attempt_with_a_deleted_remote_is_an_explicit_conflict
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      push_complete = Hive::RefactorPatrol::PrOpener.push_complete_payload(
        canonical_action_id: "fix-fp", repository: "acme/demo",
        branch: local_patch.branch, commit_sha: local_patch.commit_sha
      )

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        publication_state: { "push_complete" => push_complete },
        record_intent: ->(**) { flunk "completed attempt must not reopen the push phase" }
      )

      assert_equal "remote_branch_conflict", result.outcome
      assert_empty gh.pushed
      assert_empty gh.created
    end
  end

  def test_existing_creation_intent_reconciles_only_despite_later_trunk_drift
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = isolated_patch(repo)
      File.write(File.join(repo, "README.md"), "trunk advanced\n")
      run!("git", "-C", repo, "add", "README.md")
      run!("git", "-C", repo, "commit", "-m", "advance trunk", "--quiet")

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        creation_attempted: true,
        record_intent: -> { flunk "existing intent must never be submitted again" }
      )

      assert_equal "remote_outcome_unknown", result.outcome
      refute result.terminal
      assert_empty result.receipts
      assert_empty gh.pushed
      assert_empty gh.created
    ensure
      FileUtils.rm_rf(local_patch&.worktree_path)
    end
  end

  def test_revoked_final_push_fence_records_no_request_intent_and_leaves_remote_unchanged
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      intents = 0

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        authorize_push: -> { false }, record_intent: -> { intents += 1; true }
      )

      assert_equal "authority_revoked", result.outcome
      refute result.terminal
      assert_equal 0, intents, "a rejected final fence proves that no request was sent"
      refute result.receipts.key?("creation_intent")
      assert_empty gh.pushed
      assert_empty gh.created
    end
  end

  def test_push_rechecks_authority_after_persisting_intent_and_before_request
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      fences = [ true, false ]
      phases = []

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        authorize_push: -> { fences.shift },
        record_intent: ->(phase:, payload:) { phases << phase; !payload.empty? }
      )

      assert_equal "authority_revoked", result.outcome
      assert_equal [ "push_intent" ], phases
      assert_empty gh.pushed
      assert_empty gh.created
    end
  end

  def test_persisted_push_can_resume_at_pr_create_without_a_duplicate_push
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      publication = {}
      persist = lambda do |phase:, payload:|
        publication[phase] = payload
        true
      end

      blocked = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: persist,
        authorize_create: -> { false }
      )

      assert_equal "authority_revoked", blocked.outcome
      assert_equal %w[push_complete push_intent], publication.keys.sort
      assert_equal 1, gh.pushed.size
      assert_empty gh.created

      gh.remote_oid = local_patch.commit_sha
      recovered = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        publication_state: {
          "push_intent" => publication.fetch("push_intent"),
          "push_complete" => publication.fetch("push_complete")
        },
        record_intent: persist
      )

      assert_equal "pr_opened", recovered.outcome
      assert_equal 1, gh.pushed.size, "a reconciled push must not be repeated"
      assert_equal 1, gh.created.size
      assert publication.key?("pr_create_intent")
    end
  end

  def test_landed_push_recovers_when_completion_receipt_persistence_failed
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      publication = {}
      fail_completion = lambda do |phase:, payload:|
        next false if phase == "push_complete"

        publication[phase] = payload
        true
      end

      interrupted = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: fail_completion
      )

      assert_equal "remote_outcome_unknown", interrupted.outcome
      assert_equal [ "push_intent" ], publication.keys
      assert_equal 1, gh.pushed.size
      assert_empty gh.created

      gh.remote_oid = local_patch.commit_sha
      persist = lambda do |phase:, payload:|
        publication[phase] = payload
        true
      end
      recovered = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        publication_state: { "push_intent" => publication.fetch("push_intent") },
        record_intent: persist
      )

      assert_equal "pr_opened", recovered.outcome
      assert_equal 1, gh.pushed.size
      assert_equal 1, gh.created.size
      assert_equal %w[pr_create_intent push_complete push_intent], publication.keys.sort
    end
  end

  def test_github_enterprise_host_targets_auth_lookup_and_create
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      gh.create_output = "https://github.corp.example/acme/demo/pull/9\n"
      gh.repository = { "repository" => "acme/demo", "host" => "github.corp.example" }
      enterprise_source = source.merge(
        "url" => "https://github.corp.example/acme/demo/pull/7"
      )

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: enterprise_source,
        record_intent: -> { true }
      )

      assert_equal "pr_opened", result.outcome
      assert_equal [ "github.corp.example" ], gh.authenticated_hosts
      assert_equal "github.corp.example", gh.lookups.first.fetch(:host)
      assert_equal "acme/demo", gh.lookups.first.fetch(:repository)
      assert_equal "github.corp.example/acme/demo",
                   gh.created.first.fetch(gh.created.first.index("--repo") + 1)
    end
  end


  def test_repository_identity_drift_blocks_lookup_push_and_create
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      gh.repository = { "repository" => "other/repo", "host" => "github.com" }

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { flunk "identity drift must not persist intent" }
      )

      assert_equal "repository_identity_drift", result.outcome
      refute result.terminal
      assert_equal 1, gh.lookups.size, "explicit source-repository reconciliation remains read-only"
      assert_empty gh.pushed
      assert_empty gh.created
    end
  end

  def test_ambiguous_prior_intent_reconciles_without_second_create
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source, creation_attempted: true,
        record_intent: -> { true }
      )

      assert_equal "remote_outcome_unknown", result.outcome
      refute result.terminal
      assert_empty gh.pushed
      assert_empty gh.created
    end
  end

  def test_record_intent_is_a_required_keyword
    with_tmp_git_repo do |repo|
      gh = FakeGh.new

      assert_raises(ArgumentError) do
        opener(repo, gh, Handoff.new).open(
          thesis: thesis, patch: patch(repo), job_id: "job-7",
          canonical_action_id: "fix-fp", source: source
        )
      end

      assert_empty gh.pushed
      assert_empty gh.created
    end
  end

  def test_create_stops_when_intent_store_does_not_return_exact_true
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      handoff = Handoff.new

      result = opener(repo, gh, handoff).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { nil }
      )

      assert_equal "intent_persist_failed", result.outcome
      refute result.terminal
      assert_empty gh.pushed
      assert_empty gh.created
      assert_empty handoff.calls
    end
  end


  def test_final_create_fence_runs_after_intent_and_push
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      phases = []

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: ->(phase:, payload:) { phases << phase; !payload.empty? },
        authorize_push: -> { true },
        authorize_create: -> { false }
      )

      assert_equal "authority_revoked", result.outcome
      assert_equal %w[push_intent push_complete], phases
      assert_equal 1, gh.pushed.size
      assert_empty gh.created
    end
  end

  def test_create_rechecks_authority_after_persisting_intent_and_before_request
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      create_fences = [ true, false ]
      phases = []

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: ->(phase:, payload:) { phases << phase; !payload.empty? },
        authorize_create: -> { create_fences.shift }
      )

      assert_equal "authority_revoked", result.outcome
      assert_equal %w[push_intent push_complete pr_create_intent], phases
      assert_equal 1, gh.pushed.size
      assert_empty gh.created
    end
  end

  def test_create_rechecks_trunk_after_push_and_before_persisting_create_intent
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = isolated_patch(repo)
      remote_reads = 0
      gh.before_remote_read = lambda do
        remote_reads += 1
        next unless remote_reads == 2

        File.write(File.join(repo, "README.md"), "trunk advanced during publication\n")
        run!("git", "-C", repo, "add", "README.md")
        run!("git", "-C", repo, "commit", "-m", "advance before create intent", "--quiet")
      end
      phases = []

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: ->(phase:, payload:) { phases << phase; !payload.empty? }
      )

      assert_equal "trunk_drift_retry", result.outcome
      assert_equal run!("git", "-C", repo, "rev-parse", "HEAD").strip,
                   result.observed_head_sha
      assert_equal %w[push_intent push_complete], phases
      assert_equal 1, gh.pushed.size
      assert_empty gh.created
    ensure
      FileUtils.rm_rf(local_patch&.worktree_path)
    end
  end

  def test_create_stops_if_remote_branch_changes_after_create_intent
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      create_fences = 0

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: ->(**) { true },
        authorize_create: lambda {
          create_fences += 1
          gh.remote_oid = "f" * 40 if create_fences == 2
          true
        }
      )

      assert_equal "remote_outcome_unknown", result.outcome
      assert_empty gh.created
      assert_empty gh.verified
    end
  end

  def test_created_pr_identity_is_verified_before_review_handoff
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      gh.verification_error = "head changed"
      handoff = Handoff.new

      result = opener(repo, gh, handoff).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: ->(**) { true }
      )

      assert_equal "remote_outcome_unknown", result.outcome
      assert_equal 1, gh.created.size
      assert_equal 1, gh.verified.size
      assert_empty handoff.calls
    end
  end

  def test_create_stops_when_intent_store_raises
    with_tmp_git_repo do |repo|
      gh = FakeGh.new

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { raise IOError, "disk full" }
      )

      assert_equal "intent_persist_failed", result.outcome
      refute result.terminal
      assert_includes result.receipts.fetch("intent_error"), "disk full"
      assert_empty gh.created
    end
  end

  def test_existing_closed_pr_is_terminal_without_replacement
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      gh.prs = [ remote_pr(local_patch, state: "CLOSED") ]
      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { true }
      )

      assert_equal "closed_without_merge", result.outcome
      assert result.terminal
      assert_empty gh.pushed
      assert_empty gh.created
    end
  end

  def test_single_full_identity_match_wins_over_earlier_nonmatching_branch_pr
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      nonmatching = remote_pr(local_patch, number: 3, state: "CLOSED")
      nonmatching["body"] = "unrelated PR on a reused branch"
      gh.prs = [
        remote_pr(local_patch, number: 9),
        nonmatching
      ]

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { true }
      )

      assert_equal "pr_opened", result.outcome
      assert_equal "https://github.com/acme/demo/pull/9", result.pr_url
      assert_empty gh.created
    end
  end

  def test_reconciliation_accepts_canonical_repository_casing_from_github
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      candidate = remote_pr(local_patch)
      candidate["url"] = "https://github.com/Acme/Demo/pull/8"
      candidate["headRepository"] = { "nameWithOwner" => "Acme/Demo" }
      gh.prs = [ candidate ]

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { true }
      )

      assert_equal "pr_opened", result.outcome
      assert result.terminal
      assert_empty gh.created
    end
  end

  def test_open_reconciliation_requires_explicit_non_draft_state
    with_tmp_git_repo do |repo|
      local_patch = patch(repo)
      {
        "draft" => ->(candidate) { candidate["isDraft"] = true },
        "missing isDraft" => ->(candidate) { candidate.delete("isDraft") }
      }.each do |label, mutate|
        gh = FakeGh.new
        handoff = Handoff.new
        candidate = remote_pr(local_patch)
        mutate.call(candidate)
        gh.prs = [ candidate ]

        result = opener(repo, gh, handoff).open(
          thesis: thesis, patch: local_patch, job_id: "job-7",
          canonical_action_id: "fix-fp", source: source,
          record_intent: -> { flunk "#{label} recovery must not persist intent" }
        )

        assert_equal "remote_pr_conflict", result.outcome, label
        refute result.terminal, label
        assert_equal [ "draft_state" ],
                     result.receipts.dig("remote_pr_candidates", 0, "conflicts"), label
        assert_empty handoff.calls, label
        assert_empty gh.pushed, label
        assert_empty gh.created, label
      end
    end
  end

  def test_non_open_reconciliation_preserves_closed_and_merged_recovery_without_draft_metadata
    with_tmp_git_repo do |repo|
      local_patch = patch(repo)
      cases = [
        [ "MERGED", true, "merged", true ],
        [ "CLOSED", :missing, "closed_without_merge", false ]
      ]

      cases.each do |state, draft, outcome, handoff_expected|
        gh = FakeGh.new
        handoff = Handoff.new
        candidate = remote_pr(local_patch, state: state)
        draft == :missing ? candidate.delete("isDraft") : candidate["isDraft"] = draft
        gh.prs = [ candidate ]

        result = opener(repo, gh, handoff).open(
          thesis: thesis, patch: local_patch, job_id: "job-7",
          canonical_action_id: "fix-fp", source: source,
          record_intent: -> { flunk "existing #{state} PR must not persist intent" }
        )

        assert_equal outcome, result.outcome, state
        assert result.terminal, state
        assert_equal handoff_expected ? 1 : 0, handoff.calls.size, state
      end
    end
  end

  def test_multiple_full_identity_matches_are_a_visible_nonterminal_conflict
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      gh.prs = [ remote_pr(local_patch, number: 9), remote_pr(local_patch, number: 3) ]

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { true }
      )

      assert_equal "remote_pr_conflict", result.outcome
      refute result.terminal
      assert_equal [ "multiple_identity_matches" ], result.receipts.fetch("remote_conflicts")
      assert_equal [ 3, 9 ], result.receipts.fetch("matching_pr_numbers")
      refute result.receipts.key?("remote_pr_candidates")
      assert_empty gh.pushed
      assert_empty gh.created
    end
  end

  def test_no_full_identity_match_surfaces_every_nonmatching_record
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      wrong_marker = remote_pr(local_patch, number: 3)
      wrong_marker["body"] = "unrelated"
      wrong_head = remote_pr(local_patch, number: 9)
      wrong_head["headRefOid"] = "deadbeef"
      gh.prs = [ wrong_head, wrong_marker ]

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { true }
      )

      assert_equal "remote_pr_conflict", result.outcome
      refute result.terminal
      assert_equal [ "no_identity_match" ], result.receipts.fetch("remote_conflicts")
      candidates = result.receipts.fetch("remote_pr_candidates")
      assert_equal [ 3, 9 ], candidates.map { |candidate| candidate.fetch("number") }
      assert_equal [ [ "action_marker" ], [ "head_sha" ] ],
                   candidates.map { |candidate| candidate.fetch("conflicts") }
      assert_empty gh.pushed
      assert_empty gh.created
    end
  end

  def test_open_pr_remains_incomplete_until_handoff_succeeds
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      gh.prs = [ remote_pr(local_patch) ]
      result = opener(repo, gh, Handoff.new(result: nil)).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { true }
      )

      assert_equal "review_handoff_pending", result.outcome
      refute result.terminal
      assert_equal "https://github.com/acme/demo/pull/8", result.pr_url
    end
  end

  def test_existing_pr_handoff_is_fenced_before_enqueue
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      gh.prs = [ remote_pr(local_patch) ]
      handoff = Handoff.new

      result = opener(repo, gh, handoff).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        authorize_handoff: -> { false }, record_intent: -> { true }
      )

      assert_equal "review_handoff_pending", result.outcome
      refute result.terminal
      assert_empty handoff.calls
    end
  end

  def test_existing_remote_pr_reconciles_after_registered_trunk_advances
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      handoff = Handoff.new
      local_patch = isolated_patch(repo)
      gh.prs = [ remote_pr(local_patch) ]
      File.write(File.join(repo, "README.md"), "trunk advanced\n")
      run!("git", "-C", repo, "add", "README.md")
      run!("git", "-C", repo, "commit", "-m", "advance trunk", "--quiet")

      result = opener(repo, gh, handoff).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        creation_attempted: true, record_intent: -> { true }
      )

      assert_equal "pr_opened", result.outcome
      assert result.terminal
      assert_equal "https://github.com/acme/demo/pull/8", result.pr_url
      assert_equal 1, handoff.calls.size
      assert_empty gh.pushed
      assert_empty gh.created
    ensure
      FileUtils.rm_rf(local_patch&.worktree_path)
    end
  end

  def test_existing_remote_must_match_every_durable_identity
    with_tmp_git_repo do |repo|
      local_patch = patch(repo)
      mutations = {
        "missing number" => ->(pr) { pr.delete("number") },
        "wrong marker" => ->(pr) { pr["body"] = "<!-- hive-refactor-patrol action=other -->" },
        "missing head" => ->(pr) { pr.delete("headRefOid") },
        "wrong head" => ->(pr) { pr["headRefOid"] = "deadbeef" },
        "wrong base" => ->(pr) { pr["baseRefName"] = "release" },
        "wrong head repository" => lambda { |pr|
          pr["headRepository"] = { "nameWithOwner" => "other/demo" }
        },
        "wrong URL repository" => lambda { |pr|
          pr["url"] = "https://github.com/other/demo/pull/8"
        },
        "wrong URL host" => lambda { |pr|
          pr["url"] = "https://evil.example/acme/demo/pull/8"
        }
      }

      mutations.each do |label, mutate|
        gh = FakeGh.new
        handoff = Handoff.new
        candidate = Marshal.load(Marshal.dump(remote_pr(local_patch)))
        mutate.call(candidate)
        gh.prs = [ candidate ]

        result = opener(repo, gh, handoff).open(
          thesis: thesis, patch: local_patch, job_id: "job-7",
          canonical_action_id: "fix-fp", source: source,
          record_intent: -> { true }
        )

        assert_equal "remote_pr_conflict", result.outcome, label
        refute result.terminal, label
        assert_empty gh.pushed, label
        assert_empty gh.created, label
        assert_empty handoff.calls, label
      end
    end
  end

  def test_merged_pr_is_terminal_only_after_mandatory_review_handoff
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      handoff = Handoff.new
      local_patch = patch(repo)
      gh.prs = [ remote_pr(local_patch, state: "MERGED") ]

      result = opener(repo, gh, handoff).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { true }
      )

      assert_equal "merged", result.outcome
      assert result.terminal
      assert_equal "/tmp/review-task", result.review_task_path
      assert_equal true, handoff.calls.first.fetch(:mandatory)
    end
  end

  def test_merged_pr_remains_nonterminal_when_review_handoff_fails
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      gh.prs = [ remote_pr(local_patch, state: "MERGED") ]

      result = opener(repo, gh, Handoff.new(result: nil)).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { true }
      )

      assert_equal "merged_without_review_handoff", result.outcome
      refute result.terminal
    end
  end

  def test_secret_in_bounded_body_blocks_before_push
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      item = thesis
      item.problem = "credential sk-#{'a' * 48}"
      result = opener(repo, gh, Handoff.new).open(
        thesis: item, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { true }
      )

      assert_equal "secret_detected", result.outcome
      assert result.terminal
      assert_empty gh.pushed
    end
  end

  def test_body_cap_preserves_reconciliation_marker
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      item = thesis
      item.cost = "x" * (Hive::RefactorPatrol::PrOpener::MAX_BODY + 5_000)

      result = opener(repo, gh, Handoff.new).open(
        thesis: item, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { true }
      )

      assert_equal "pr_opened", result.outcome
      assert_operator gh.bodies.first.bytesize, :<=, Hive::RefactorPatrol::PrOpener::MAX_BODY
      assert gh.bodies.first.end_with?("<!-- hive-refactor-patrol action=fix-fp job=job-7 fingerprint=fp -->\n")
    end
  end

  def test_invalid_create_response_is_ambiguous_after_persisted_intent
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      gh.create_output = "warning only\n"
      intents = 0

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { intents += 1; true }
      )

      assert_equal 2, intents
      assert_equal "remote_outcome_unknown", result.outcome
      refute result.terminal
    end
  end

  def test_unreadable_diff_fails_closed_before_push
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      subject = Hive::RefactorPatrol::PrOpener.new(
        repo, cfg: Hive::Config.deep_dup(Hive::Config::DEFAULTS), gh: gh,
        review_handoff: Handoff.new,
        diff_reader: ->(_patch) { raise Hive::GitError, "unreadable diff" }
      )

      assert_raises(Hive::GitError) do
        subject.open(
          thesis: thesis, patch: patch(repo), job_id: "job-7",
          canonical_action_id: "fix-fp", source: source,
          record_intent: -> { true }
        )
      end
      assert_empty gh.pushed
    end
  end

  def test_advanced_patch_branch_fails_identity_check_before_push
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      receipt = patch(repo)
      File.write(File.join(repo, "advanced.txt"), "unvalidated\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "unvalidated advance", "--quiet")

      error = assert_raises(Hive::GitError) do
        opener(repo, gh, Handoff.new).open(
          thesis: thesis, patch: receipt, job_id: "job-7",
          canonical_action_id: "fix-fp", source: source,
          record_intent: -> { true }
        )
      end

      assert_includes error.message, "commit changed before publication"
      assert_empty gh.pushed
      assert_empty gh.created
    end
  end

  def test_invalid_publication_state_is_rejected_before_remote_lookup
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        publication_state: { "unexpected" => {} }, record_intent: -> { true }
      )

      assert_equal "invalid_publication_state", result.outcome
      assert_empty gh.lookups
    end
  end

  def test_persisted_push_intent_conflicts_with_a_third_remote_head
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      expected = "a" * 40
      gh.remote_oid = "b" * 40
      state = {
        "push_intent" => Hive::RefactorPatrol::PrOpener.push_intent_payload(
          canonical_action_id: "fix-fp", repository: "acme/demo",
          branch: local_patch.branch, commit_sha: local_patch.commit_sha,
          expected_remote_oid: expected
        )
      }

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        publication_state: state, record_intent: -> { true }
      )

      assert_equal "remote_branch_conflict", result.outcome
      assert_empty gh.pushed
    end
  end

  def test_remote_head_is_rechecked_before_create_intent
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      lookups = 0
      gh.define_singleton_method(:remote_branch_oid) do |*_, **|
        lookups += 1
        lookups == 1 ? nil : "f" * 40
      end

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: ->(**) { true }
      )

      assert_equal "remote_branch_conflict", result.outcome
      assert_equal 2, lookups
      assert_empty gh.created
    end
  end

  def test_non_gateway_create_exception_after_intent_is_remote_unknown
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      gh.define_singleton_method(:capture3) { |*, **| raise RuntimeError, "transport decoder crashed" }

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: ->(**) { true }
      )

      assert_equal "remote_outcome_unknown", result.outcome
      assert_includes result.receipts.fetch("error"), "transport decoder crashed"
    end
  end

  def test_handoff_exception_is_a_nonterminal_visible_receipt
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      handoff = Handoff.new
      handoff.define_singleton_method(:enqueue) { |**| raise IOError, "review state unavailable" }

      result = opener(repo, gh, handoff).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: ->(**) { true }
      )

      assert_equal "review_handoff_pending", result.outcome
      refute result.terminal
      assert_includes result.receipts.fetch("handoff_error"), "review state unavailable"
    end
  end

  # ReviewHandoff raises ArgumentError for metadata that can never
  # materialize on a retry and Conflict for duplicate/conflicting task state
  # needing a human. Both used to surface as an eternally retried
  # review_handoff_pending; they must settle terminally with the evidence.
  def test_handoff_conflict_and_invalid_metadata_settle_terminally
    {
      Hive::Patrol::ReviewHandoff::Conflict => "duplicate complete tasks for fp",
      ArgumentError => "patrol review handoff requires head_sha"
    }.each do |error_class, message|
      with_tmp_git_repo do |repo|
        gh = FakeGh.new
        handoff = Handoff.new
        handoff.define_singleton_method(:enqueue) { |**| raise error_class, message }

        result = opener(repo, gh, handoff).open(
          thesis: thesis, patch: patch(repo), job_id: "job-7",
          canonical_action_id: "fix-fp", source: source,
          record_intent: ->(**) { true }
        )

        assert_equal "review_handoff_failed", result.outcome, error_class.name
        assert result.terminal, "#{error_class.name} retries can only re-fail"
        assert_equal result.pr_url, result.receipts.fetch("pr_url"), error_class.name
        assert_includes result.receipts.fetch("handoff_error"), error_class.name
        assert_includes result.receipts.fetch("handoff_error"), message, error_class.name
      end
    end
  end

  def test_create_transport_failure_after_intent_is_remote_unknown
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      gh.create_failure = "permission denied"

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: ->(**) { true }
      )

      assert_equal "remote_outcome_unknown", result.outcome
      assert_includes result.receipts.fetch("error"), "gh pr create failed"
    end
  end

  def test_invalid_source_url_is_a_gateway_error
    with_tmp_git_repo do |repo|
      result = opener(repo, FakeGh.new, Handoff.new).open(
        thesis: thesis, patch: patch(repo), job_id: "job-7",
        canonical_action_id: "fix-fp", source: source.merge("url" => "http://["),
        record_intent: -> { true }
      )

      assert_equal "gh_error", result.outcome
      assert_includes result.receipts.fetch("error"), "source PR URL is invalid"
    end
  end

  def test_structured_create_intent_is_validated_without_resubmission
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      state = {
        "pr_create_intent" => Hive::RefactorPatrol::PrOpener.pr_create_intent_payload(
          canonical_action_id: "fix-fp", repository: "acme/demo",
          branch: local_patch.branch, commit_sha: local_patch.commit_sha
        )
      }

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        publication_state: state, record_intent: -> { flunk "must not resubmit" }
      )

      assert_equal "remote_outcome_unknown", result.outcome
      assert_empty gh.pushed
      assert_empty gh.created
    end
  end

  def test_branch_diff_and_git_helpers_fail_closed_on_unverified_git_state
    with_tmp_git_repo do |repo|
      subject = Hive::RefactorPatrol::PrOpener.new(
        repo, cfg: Hive::Config.deep_dup(Hive::Config::DEFAULTS),
        gh: FakeGh.new, review_handoff: Handoff.new
      )
      local_patch = patch(repo)
      assert_kind_of String, subject.send(:branch_diff, local_patch)

      invalid = local_patch.dup
      invalid.publication_base_sha = "f" * 40
      error = assert_raises(Hive::GitError) { subject.send(:branch_diff, invalid) }
      assert_includes error.message, "cannot read refactor PR diff"

      error = assert_raises(Hive::GitError) { subject.send(:assert_patch_identity!, invalid) }
      assert_includes error.message, "does not descend from publication base"

      error = assert_raises(Hive::GitError) { subject.send(:git_output!, repo, "not-a-git-command") }
      assert_includes error.message, "git not-a-git-command failed"
    end
  end

  def test_superseded_patch_commits_must_be_full_object_ids
    with_tmp_git_repo do |repo|
      error = assert_raises(Hive::GitError) do
        opener(repo, FakeGh.new, Handoff.new).open(
          thesis: thesis, patch: patch(repo), job_id: "job-7",
          canonical_action_id: "fix-fp", source: source,
          superseded_patch_commits: [ "short" ], record_intent: -> { true }
        )
      end

      assert_includes error.message, "superseded refactor patch commit is invalid"
    end
  end

  private

  def opener(repo, gh, handoff)
    Hive::RefactorPatrol::PrOpener.new(
      repo, cfg: Hive::Config.deep_dup(Hive::Config::DEFAULTS), gh: gh,
      review_handoff: handoff, diff_reader: ->(_patch) { "diff --git a/lib/a.rb b/lib/a.rb\n+ok\n" }
    )
  end

  def patch(repo)
    sha = run!("git", "-C", repo, "rev-parse", "HEAD").strip
    branch = run!("git", "-C", repo, "branch", "--show-current").strip
    Hive::RefactorPatrol::Fixer::Result.new(
      outcome: "validated", terminal: false, branch: branch,
      worktree_path: repo, analysis_sha: sha, publication_base_sha: sha,
      commit_sha: sha, validation: {
        "passed" => true, "commands" => [ { "name" => "test", "exit_code" => 0 } ]
      },
      changed_paths: [ "lib/a.rb" ], diff_lines: 2, details: {}
    )
  end

  def isolated_patch(repo)
    base = run!("git", "-C", repo, "rev-parse", "HEAD").strip
    path = File.join(File.dirname(repo), "#{File.basename(repo)}-refactor-patch")
    branch = "hive-refactor/test-patch"
    run!("git", "-C", repo, "worktree", "add", "-b", branch, path, base, "--quiet")
    File.write(File.join(path, "refactor.txt"), "validated patch\n")
    run!("git", "-C", path, "add", "refactor.txt")
    run!("git", "-C", path, "commit", "-m", "validated patch", "--quiet")
    commit = run!("git", "-C", path, "rev-parse", "HEAD").strip
    Hive::RefactorPatrol::Fixer::Result.new(
      outcome: "validated", terminal: false, branch: branch,
      worktree_path: path, analysis_sha: base, publication_base_sha: base,
      commit_sha: commit, validation: {
        "passed" => true, "commands" => [ { "name" => "test", "exit_code" => 0 } ]
      },
      changed_paths: [ "refactor.txt" ], diff_lines: 1, details: {}
    )
  end

  def remote_pr(local_patch, number: 8, state: "OPEN")
    {
      "number" => number,
      "state" => state,
      "isDraft" => false,
      "url" => "https://github.com/acme/demo/pull/#{number}",
      "body" => "Refactor\n\n<!-- hive-refactor-patrol action=fix-fp job=job-7 fingerprint=fp -->\n",
      "headRefOid" => local_patch.commit_sha,
      "baseRefName" => "master",
      "headRepository" => { "nameWithOwner" => "acme/demo" }
    }
  end

  def source
    {
      "url" => "https://github.com/acme/demo/pull/7", "repository" => "acme/demo",
      "base_branch" => "master"
    }
  end

  def thesis
    Hive::RefactorPatrol::Thesis.new(
      id: "extract", feature_id: "checkout", feature: "Checkout",
      problem: "Checkout mixes concerns", cost: "Changes fan out",
      evidence: [ { "file" => "lib/a.rb", "line" => 4, "claim" => "two responsibilities" } ],
      proposed_refactor: "Extract orchestration", feature_boundary: {},
      feature_hotspot: { "coupling" => 8 },
      expected_leverage: { "score" => 64, "mechanism" => "separate change axes" },
      confidence: "medium", risk: { "flags" => [] },
      required_validation: { "commands" => [ "test" ] }, admissible: true,
      admissibility_reason: "", follow_up_approval_state: "pending", fingerprint: "fp"
    )
  end
end
