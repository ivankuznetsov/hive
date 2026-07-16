require "test_helper"
require "yaml"
require "hive/config"
require "hive/markers"
require "hive/patrol/pr_opener"
require "hive/patrol/finding"
require "hive/task"

class HivePatrolPrOpenerTest < Minitest::Test
  include HiveTestHelper

  BASE_SHA = "a" * 40
  HEAD_SHA = "b" * 40

  FakePatch = Struct.new(:finding, :branch, :worktree_path, :validation,
                         :passed, :diffstat, :base_sha, :head_sha, keyword_init: true)

  class FakeGh
    attr_reader :pushed, :push_options, :created_args, :git_commands
    attr_accessor :prs, :diff, :diff_status, :head_sha, :status_output,
                  :remote_oid, :base_remote_oid, :created_base_oid, :push_updates_remote

    def initialize
      @prs = []
      @diff = "diff --git a/app.rb b/app.rb\n+puts 'ok'\n"
      @diff_status = 0
      @head_sha = HivePatrolPrOpenerTest::HEAD_SHA
      @status_output = ""
      @remote_oid = nil
      @base_remote_oid = HivePatrolPrOpenerTest::BASE_SHA
      @push_updates_remote = true
      @pushed = []
      @push_options = []
      @created_args = nil
      @git_commands = []
    end

    def lookup_prs_for_branch(_path, _branch, cfg: nil)
      return @prs unless @created_args

      @prs + [
        {
          "state" => "OPEN", "url" => "https://example.com/pr/2",
          "headRefOid" => @head_sha, "baseRefOid" => (@created_base_oid || @base_remote_oid),
          "baseRefName" => "master"
        }
      ]
    end

    def ensure_authenticated!(_cfg = nil)
      true
    end

    def push_branch!(path, branch, cfg: nil, expected_remote_oid: nil, expected_remote_absent: false)
      @pushed << [ path, branch ]
      @push_options << {
        expected_remote_oid: expected_remote_oid,
        expected_remote_absent: expected_remote_absent
      }
      @remote_oid = @head_sha if @push_updates_remote
    end

    def remote_branch_oid(_path, branch, cfg: nil)
      branch == "master" ? @base_remote_oid : @remote_oid
    end

    def capture3(*cmd, chdir: nil, cfg: nil)
      if cmd[0] == "git"
        @git_commands << cmd
        operation = cmd[3]
        case operation
        when "rev-parse"
          return [ "#{@head_sha}\n", "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
        when "status"
          return [ @status_output, "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
        when "diff"
          return [ @diff, "diff failed", Hive::Gh::CommandStatus.new(exitstatus: @diff_status) ]
        end
      end

      @created_args = cmd
      [ "https://example.com/pr/2\n", "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
    end
  end

  class FailingReviewHandoff
    def enqueue(**)
      raise "disk full"
    end
  end

  def before_setup
    super
    original = Hive::TaskCounter.method(:next!)
    counter = 40
    @restore_task_counter = lambda do
      Hive::TaskCounter.define_singleton_method(:next!, original)
    end
    Hive::TaskCounter.define_singleton_method(:next!) do
      counter += 1
    end
  end

  def after_teardown
    @restore_task_counter&.call
    super
  end

  def cfg(draft: true)
    Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      { "default_branch" => "master", "patrol" => { "draft_prs" => draft } }
    )
  end

  def finding
    Hive::Patrol::Finding.new(
      id: "f1",
      feature_id: "feature",
      category: "bug",
      severity: "high",
      confidence: "medium",
      title: "Fix bug",
      description: "bug details",
      recommendation: "fix it",
      scope: "cross_feature",
      contract: "Every accepted job must eventually be delivered.",
      impact: "Accepted jobs disappear without an error.",
      root_cause: "The handoff clears durable state before acknowledgement.",
      reproduction: "Interrupt the handoff after dequeue and before acknowledgement.",
      validation: "Run the handoff interruption regression and delivery suite.",
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "puts" } ],
      alpha_score: 88,
      fingerprint: "fp1"
    )
  end

  def patch(worktree_path: Dir.pwd, passed: true)
    FakePatch.new(
      finding: finding,
      branch: "hive-patrol/feature-fp1",
      worktree_path: worktree_path,
      passed: passed,
      validation: { "commands" => [ { "name" => "test", "command" => "rake", "exit_code" => 0 } ] },
      diffstat: " app.rb | 1 +",
      base_sha: BASE_SHA,
      head_sha: HEAD_SHA
    )
  end

  def matching_pr(state: "OPEN", url: "https://example.com/pr/1")
    {
      "state" => state,
      "url" => url,
      "headRefOid" => HEAD_SHA,
      "baseRefOid" => BASE_SHA,
      "baseRefName" => "master"
    }
  end

  def test_validated_patch_opens_draft_pr_records_mapping_and_enqueues_review_task
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert result.opened?
      assert_equal [ [ dir, "hive-patrol/feature-fp1" ] ], gh.pushed
      assert_equal [ { expected_remote_oid: nil, expected_remote_absent: true } ], gh.push_options
      assert_includes gh.created_args, "--draft"
      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "https://example.com/pr/2", fingerprints["fp1"]["pr_url"]
      assert_equal "open", fingerprints["fp1"]["state"]
      assert_equal "feature", fingerprints["fp1"]["feature_id"]

      refute_nil result.review_task_path
      task = Hive::Task.new(result.review_task_path)
      assert_equal "review", task.stage_name
      assert_equal "patrol-feature-fp1", task.slug
      assert task.id, "patrol-created review tasks must get normal task ids"
      assert_equal "Patrol: Fix bug", task.display_name
      assert_equal :none, Hive::Markers.current(task.state_file).name
      assert File.directory?(task.reviews_dir)

      pointer = YAML.safe_load(File.read(task.worktree_yml_path))
      assert_equal dir, pointer.fetch("path")
      assert_equal "hive-patrol/feature-fp1", pointer.fetch("branch")
      assert_equal HEAD_SHA, pointer.fetch("execute_base_head")

      pr_md = File.read(File.join(task.folder, "pr.md"))
      assert_includes pr_md, "pr_url: https://example.com/pr/2"
      assert_includes File.read(task.state_file), "# Patrol: Fix bug"
    end
  end

  def test_pr_body_preserves_alpha_and_root_cause_evidence
    opener = Hive::Patrol::PrOpener.new(Dir.pwd, cfg: cfg, gh: FakeGh.new)

    body = opener.send(:body_for, finding, patch)

    assert_includes body, "Alpha: `88`"
    assert_includes body, "Scope: `cross_feature`"
    assert_includes body, "## Contract and impact"
    assert_includes body, finding.contract
    assert_includes body, finding.impact
    assert_includes body, "## Root cause"
    assert_includes body, finding.root_cause
    assert_includes body, "## Reproduction"
    assert_includes body, finding.reproduction
    assert_includes body, finding.validation
  end

  def test_pr_body_preserves_machine_observed_fix_proof
    observed = patch
    observed.validation["fix_proof"] = {
      "root_cause" => "Confirmed queue deletion before acknowledgement.",
      "audited_paths" => %w[app.rb lib/queue.rb],
      "configured_command" => "bundle exec ruby test/queue_test.rb",
      "before" => { "exit_code" => 1, "timed_out" => false },
      "after" => { "exit_code" => 0, "timed_out" => false }
    }

    body = Hive::Patrol::PrOpener.new(Dir.pwd, cfg: cfg, gh: FakeGh.new).send(:body_for, finding, observed)

    assert_includes body, "## Observed fix proof"
    assert_includes body, "Agent-reported root cause"
    assert_includes body, "Confirmed queue deletion"
    assert_includes body, "exit=1"
    assert_includes body, "exit=0"
  end

  def test_secret_in_agent_authored_title_blocks_before_push
    with_tmp_dir do |dir|
      gh = FakeGh.new
      unsafe = finding
      unsafe.title = "Fix sk-#{'x' * 24}"

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(
        unsafe, patch(worktree_path: dir)
      )

      assert_equal :blocked, result.status
      assert_equal "secret_detected", result.reason
      assert_empty gh.pushed
    end
  end

  def test_diff_acquisition_failure_blocks_publication
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.diff_status = 1

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/secret scan failed/, result.detail)
      assert_empty gh.pushed
    end
  end

  def test_review_handoff_failure_is_visible_and_retryable
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new

      result = Hive::Patrol::PrOpener.new(
        dir,
        cfg: cfg,
        gh: gh,
        review_handoff: FailingReviewHandoff.new
      ).open(finding, patch(worktree_path: dir))

      assert_equal :opened_review_handoff_failed, result.status
      assert result.opened?
      assert result.review_handoff_failed?
      assert_equal "review_handoff_failed", result.reason
      assert_nil result.review_task_path

      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "review_handoff_failed", fingerprints.fetch("fp1").fetch("state")
      refute Hive::Patrol::Fingerprint.known_active?(fingerprints, "fp1"),
             "failed review handoff must remain retryable instead of becoming an active PR skip"
    end
  end

  def test_review_handoff_frontmatter_handles_yaml_sensitive_values
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      unsafe = finding
      unsafe.id = "finding: one\nsecond"
      unsafe.fingerprint = "fp: one\nsecond"

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(unsafe, patch(worktree_path: dir))

      assert result.opened?
      task = Hive::Task.new(result.review_task_path)
      task_frontmatter = YAML.safe_load(File.read(task.state_file).match(/\A---\s*\n(.*?)\n---/m)[1])
      pr_frontmatter = Hive::Gh.pr_frontmatter(File.join(task.folder, "pr.md"))

      assert_equal unsafe.id, task_frontmatter.fetch("patrol_finding_id")
      assert_equal unsafe.fingerprint, task_frontmatter.fetch("patrol_fingerprint")
      assert_equal "https://example.com/pr/2", pr_frontmatter.fetch("pr_url")
      assert_equal unsafe.id, pr_frontmatter.fetch("patrol_finding_id")
      assert_equal unsafe.fingerprint, pr_frontmatter.fetch("patrol_fingerprint")
    end
  end

  def test_existing_open_pr_skips_duplicate
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.prs = [ matching_pr ]
      gh.remote_oid = HEAD_SHA

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_equal :skipped, result.status
      assert_equal "existing_pr", result.reason
      refute_nil result.review_task_path
      assert_empty gh.pushed
    end
  end

  def test_existing_open_pr_with_failed_handoff_is_skipped_and_retryable
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.prs = [ matching_pr ]
      gh.remote_oid = HEAD_SHA

      result = Hive::Patrol::PrOpener.new(
        dir,
        cfg: cfg,
        gh: gh,
        review_handoff: FailingReviewHandoff.new
      ).open(finding, patch(worktree_path: dir))

      assert_equal :skipped, result.status
      assert_equal "review_handoff_failed", result.reason
      assert_nil result.review_task_path
      assert_empty gh.pushed

      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "review_handoff_failed", fingerprints.fetch("fp1").fetch("state")
      refute Hive::Patrol::Fingerprint.known_active?(fingerprints, "fp1"),
             "an existing-PR handoff failure must stay retryable, not become an active skip"
    end
  end

  def test_existing_merged_pr_does_not_enqueue_review_task
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.prs = [ matching_pr(state: "MERGED") ]

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_equal :skipped, result.status
      assert_equal "existing_pr", result.reason
      assert_nil result.review_task_path
      assert_empty gh.pushed
    end
  end

  def test_review_handoff_can_be_disabled
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      config = cfg(draft: false)
      config["patrol"]["review_prs"] = false

      result = Hive::Patrol::PrOpener.new(dir, cfg: config, gh: gh).open(finding, patch(worktree_path: dir))

      assert result.opened?
      assert_nil result.review_task_path
      refute Dir.exist?(File.join(dir, ".hive-state", "stages", "6-review"))
    end
  end

  def test_secret_in_diff_blocks_pr
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.diff = "+api_key=#{'a' * 24}\n"

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_equal :blocked, result.status
      assert_equal "secret_detected", result.reason
      assert_empty gh.pushed
    end
  end

  def test_diff_is_scanned_against_the_exact_validated_base_and_head
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      captured = nil
      gh.define_singleton_method(:capture3) do |*cmd, chdir: nil, cfg: nil|
        captured = cmd if cmd[0] == "git" && cmd[3] == "diff"
        operation = cmd[3]
        output = case operation
        when "rev-parse" then "#{@head_sha}\n"
        when "status" then @status_output
        else @diff
        end
        [ output, "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
      end

      Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_includes captured, "#{BASE_SHA}..#{HEAD_SHA}",
                      "secret scan must bind to the exact validated patch identity"
    end
  end

  def test_gh_error_during_pr_stage_cleans_up_and_returns_structured_error
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.define_singleton_method(:push_branch!) do |_path, _branch, cfg: nil, **|
        raise Hive::GhError, "push rejected"
      end

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_equal "push rejected", result.detail
      refute result.opened?
    end
  end

  def test_diff_for_gh_error_fails_closed
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.define_singleton_method(:capture3) do |*|
        raise Hive::GhError, "git diff failed"
      end

      opener = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh)
      error = assert_raises(Hive::GhError) { opener.send(:diff_for, patch(worktree_path: dir)) }
      assert_includes error.message, "git diff failed"
    end
  end


  def test_local_patch_head_and_cleanliness_are_verified_before_remote_calls
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.head_sha = "c" * 40

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/validated patch head changed/, result.detail)
      assert_empty gh.pushed
    end

    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.status_output = "?? unvalidated.txt\n"

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/worktree is dirty/, result.detail)
      assert_empty gh.pushed
    end
  end

  def test_invalid_patch_identity_and_local_git_failures_fail_closed
    with_tmp_dir do |dir|
      gh = FakeGh.new
      invalid = patch(worktree_path: dir)
      invalid.head_sha = "short"

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(finding, invalid)

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/not a full Git object id/, result.detail)
    end

    with_tmp_dir do |dir|
      gh = FakeGh.new
      original = gh.method(:capture3)
      gh.define_singleton_method(:capture3) do |*cmd, chdir: nil, cfg: nil|
        if cmd[0] == "git" && cmd[3] == "rev-parse"
          [ "", "cannot inspect HEAD", Hive::Gh::CommandStatus.new(exitstatus: 2) ]
        else
          original.call(*cmd, chdir: chdir, cfg: cfg)
        end
      end

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/cannot inspect HEAD/, result.detail)
    end
  end

  def test_existing_pr_requires_the_exact_validated_identity
    mismatches = {
      "head" => { "headRefOid" => "c" * 40 },
      "base name" => { "baseRefName" => "main" }
    }

    mismatches.each do |label, override|
      with_tmp_dir do |dir|
        gh = FakeGh.new
        gh.prs = [ matching_pr.merge(override) ]

        result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(
          finding, patch(worktree_path: dir)
        )

        assert_equal :error, result.status, label
        assert_equal "gh_error", result.reason, label
        assert_match(/existing PR identity mismatch/, result.detail, label)
        assert_empty gh.pushed, label
      end
    end
  end

  def test_new_pr_requires_the_remote_base_to_remain_at_the_validated_sha
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.base_remote_oid = "d" * 40

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/remote patrol base identity mismatch/, result.detail)
      assert_empty gh.pushed
      assert_nil gh.created_args
    end
  end

  def test_created_pr_is_reconciled_against_the_validated_base
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.created_base_oid = "d" * 40

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/existing PR identity mismatch/, result.detail)
      refute_nil gh.created_args, "the simulated base race occurs during PR creation"
    end
  end

  # After `gh pr create` succeeded, a reconciliation miss (read-after-write
  # lag) or identity mismatch must surface as an error WITHOUT losing the
  # fingerprint ledger entry: a real open PR with no mapping would be
  # re-fixed and errored against on every later cycle.
  def test_reconciliation_miss_after_pr_creation_keeps_the_ledger_mapping
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.define_singleton_method(:lookup_prs_for_branch) { |*_args, **| [] }

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_includes result.detail, "could not be reconciled"
      assert_includes result.detail, "https://example.com/pr/2",
                      "the error must name the created PR so an operator can find it"
      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "https://example.com/pr/2", fingerprints.fetch("fp1").fetch("pr_url")
      assert_equal "open", fingerprints.fetch("fp1").fetch("state"),
                   "the created PR must stay in the ledger despite the reconciliation miss"
    end
  end

  def test_identity_mismatch_after_pr_creation_keeps_the_ledger_mapping
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.created_base_oid = "d" * 40

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/existing PR identity mismatch/, result.detail)
      assert_includes result.detail, "https://example.com/pr/2",
                      "the error must name the created PR so an operator can find it"
      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "https://example.com/pr/2", fingerprints.fetch("fp1").fetch("pr_url")
      assert_equal "open", fingerprints.fetch("fp1").fetch("state"),
                   "the created PR must stay in the ledger despite the identity mismatch"
    end
  end

  def test_existing_remote_branch_is_replaced_only_with_an_exact_lease
    with_tmp_dir do |dir|
      gh = FakeGh.new
      previous = "c" * 40
      gh.remote_oid = previous

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert result.opened?
      assert_equal [ { expected_remote_oid: previous, expected_remote_absent: false } ], gh.push_options
    end
  end

  def test_remote_head_must_match_before_pr_creation_and_handoff
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.push_updates_remote = false

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(
        finding, patch(worktree_path: dir)
      )

      assert_equal :error, result.status
      assert_equal "gh_error", result.reason
      assert_match(/remote patrol branch identity mismatch/, result.detail)
      assert_nil gh.created_args
    end
  end

  def test_result_status_and_reason_contracts_are_closed
    assert_equal %i[blocked error opened opened_review_handoff_failed skipped],
                 Hive::Patrol::PrOpener::RESULT_STATUSES
    assert_equal [
      nil, "existing_pr", "gh_error", "review_handoff_failed",
      "secret_detected", "validation_failed"
    ], Hive::Patrol::PrOpener::RESULT_REASONS

    assert_raises(ArgumentError) do
      Hive::Patrol::PrOpener::Result.new(status: :unknown)
    end
    assert_raises(ArgumentError) do
      Hive::Patrol::PrOpener::Result.new(status: :error, reason: "free-form error")
    end
  end
end
