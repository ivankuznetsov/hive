require "test_helper"
require "hive/config"
require "hive/refactor_patrol/fixer"
require "hive/refactor_patrol/pr_opener"
require "hive/refactor_patrol/thesis"

class RefactorPatrolPrOpenerTest < Minitest::Test
  include HiveTestHelper

  class FakeGh
    attr_accessor :prs, :create_failure, :create_output
    attr_reader :pushed, :created, :bodies

    def initialize
      @prs = []
      @pushed = []
      @created = []
      @bodies = []
      @create_output = "https://github.com/acme/demo/pull/9\n"
    end

    def ensure_authenticated!(_cfg) = true

    def lookup_prs_for_branch(_path, _branch, cfg:)
      @prs
    end

    def push_branch!(path, branch, cfg:)
      @pushed << [ path, branch ]
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
      assert_equal 1, intents
      assert_equal [ [ repo, "master" ] ], gh.pushed
      assert_includes gh.created.first, "--repo"
      assert_includes gh.created.first, "acme/demo"
      assert_includes gh.bodies.first, "<!-- hive-refactor-patrol action=fix-fp"
      assert_equal true, handoff.calls.first.fetch(:mandatory)
      context = handoff.calls.first.fetch(:context)
      assert_equal thesis.to_h, context.fetch("thesis")
      assert_equal source, context.fetch("source_pr")
      assert_equal "job-7", context.fetch("job_id")
      assert_equal "fix-fp", context.fetch("canonical_action_id")
      assert_equal patch(repo).commit_sha, context.dig("patch", "commit_sha")
      assert_equal "/tmp/review-task", result.review_task_path
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
      assert_equal 1, gh.pushed.length
      assert_empty gh.created
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

  def test_earliest_existing_pr_is_canonical_even_when_remote_order_differs
    with_tmp_git_repo do |repo|
      gh = FakeGh.new
      local_patch = patch(repo)
      gh.prs = [
        remote_pr(local_patch, number: 9),
        remote_pr(local_patch, number: 3, state: "CLOSED")
      ]

      result = opener(repo, gh, Handoff.new).open(
        thesis: thesis, patch: local_patch, job_id: "job-7",
        canonical_action_id: "fix-fp", source: source,
        record_intent: -> { true }
      )

      assert_equal "closed_without_merge", result.outcome
      assert_equal "https://github.com/acme/demo/pull/3", result.pr_url
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

      assert_equal 1, intents
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

  def remote_pr(local_patch, number: 8, state: "OPEN")
    {
      "number" => number,
      "state" => state,
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
