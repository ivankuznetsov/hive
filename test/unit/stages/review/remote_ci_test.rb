require "test_helper"
require "hive/stages/review/remote_ci"

class ReviewRemoteCiTest < Minitest::Test
  include HiveTestHelper

  Task = Struct.new(:folder, :project_root, :slug, keyword_init: true)

  class Clock
    attr_accessor :now

    def initialize
      @now = 0.0
    end
  end

  class FakeGh
    attr_accessor :identity, :metadata, :candidates, :rollups, :push_result,
                  :jobs, :parsed_url
    attr_reader :pushes, :rollup_calls

    def initialize(url:, branch:, remote_head:)
      @url = url
      @identity = { "host" => "github.com", "repository" => "acme/app" }
      @metadata = Hive::Gh::PrMetadata.new(
        number: 42, url: url, base_ref_name: "main",
        head_ref_oid: remote_head, is_cross_repository: false, state: "OPEN"
      )
      @candidates = [
        { "number" => 42, "url" => url, "state" => "OPEN", "headRefName" => branch }
      ]
      @rollups = []
      @push_result = Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")
      @jobs = []
      @pushes = []
      @rollup_calls = 0
    end

    def parse_pull_request_url(value)
      return @parsed_url unless @parsed_url.nil?

      Hive::Gh.parse_pull_request_url(value)
    end

    def repository_identity(*) = @identity
    def pr_metadata(*) = @metadata
    def lookup_prs_for_branch(*) = @candidates

    def pr_status_rollup(*)
      @rollup_calls += 1
      raise Hive::GhError, "no rollup fixture" if @rollups.empty?

      @rollups.length > 1 ? @rollups.shift : @rollups.first
    end

    def push_branch(path, branch, **kwargs)
      @pushes << [ path, branch, kwargs ]
      @push_result
    end

    def failing_jobs_with_logs(*) = @jobs
  end

  class StubRunner
    attr_accessor :guardrail_result, :settled_head
    attr_reader :calls

    def initialize(result, guardrail_result: nil, settled_head: nil)
      @result = result
      @guardrail_result = guardrail_result
      @settled_head = settled_head
      @calls = []
    end

    def command_label = "hosted checks"

    def call(**kwargs)
      @calls << kwargs
      @result
    end
  end

  def cfg(overrides = {})
    base = {
      "review" => {
        "ci" => { "max_attempts" => 1 },
        "fix" => { "guardrail" => { "enabled" => true } },
        "github_checks" => { "enabled" => true }
      },
      "timeout_sec" => { "review_ci" => 5 }
    }
    deep_merge(base, overrides)
  end

  def deep_merge(base, overrides)
    base.merge(overrides) do |_key, left, right|
      left.is_a?(Hash) && right.is_a?(Hash) ? deep_merge(left, right) : right
    end
  end

  def rollup(head:, checks:, url: "https://github.com/acme/app/pull/42")
    { "url" => url, "headRefOid" => head, "statusCheckRollup" => checks }
  end

  def check(name: "unit", status: "COMPLETED", conclusion: "SUCCESS", **extra)
    {
      "workflowName" => "CI", "name" => name,
      "status" => status, "conclusion" => conclusion
    }.merge(extra.transform_keys(&:to_s))
  end

  def with_fixture
    with_tmp_git_repo do |repo|
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      folder = File.join(repo, ".hive-state", "stages", "6-review", "demo-task")
      FileUtils.mkdir_p(File.join(folder, "reviews"))
      task = Task.new(folder: folder, project_root: repo, slug: "demo-task")
      ctx = Hive::Stages::Review::Context.new(
        worktree_path: repo, task_folder: folder, default_branch: "master", pass: 1
      )
      gh = FakeGh.new(
        url: "https://github.com/acme/app/pull/42",
        branch: task.slug,
        remote_head: head
      )
      clock = Clock.new
      runner = Hive::Stages::Review::RemoteCi::Runner.new(
        task: task, cfg: cfg, ctx: ctx,
        pr_url: "https://github.com/acme/app/pull/42", gh: gh,
        clock: -> { clock.now }, sleeper: ->(seconds) { clock.now += seconds },
        poll_interval_sec: 1, quiet_settlement_sec: 2, no_checks_grace_sec: 2
      )

      with_replaced_singleton_method(Hive::Worktree, :canonical_root, ->(_root) { repo }) do
        with_replaced_singleton_method(
          Hive::Worktree, :read_owned_pointer,
          ->(*, **) { { "path" => repo, "branch" => task.slug } }
        ) do
          yield(repo, head, task, ctx, gh, clock, runner)
        end
      end
    end
  end

  def test_run_skips_disabled_missing_and_unlinked_tasks
    with_fixture do |_repo, _head, task, ctx, _gh, _clock, _runner|
      disabled = Hive::Stages::Review::RemoteCi.run!(
        task: task, cfg: cfg("review" => { "github_checks" => { "enabled" => false } }),
        ctx: ctx
      )
      assert_equal :skipped, disabled.status

      missing = Hive::Stages::Review::RemoteCi.run!(task: task, cfg: cfg, ctx: ctx)
      assert_equal :skipped, missing.status

      File.write(File.join(task.folder, "pr.md"), "---\npr_url: ''\n---\n")
      unlinked = Hive::Stages::Review::RemoteCi.run!(task: task, cfg: cfg, ctx: ctx)
      assert_equal :skipped, unlinked.status
      assert_equal 0, unlinked.attempts
      assert_nil unlinked.error_message
      assert_nil unlinked.limit_text
    end
  end

  def test_run_delegates_to_the_ci_fix_loop_and_returns_guardrail_state
    with_fixture do |_repo, head, task, ctx, _gh, _clock, _runner|
      File.write(
        File.join(task.folder, "pr.md"),
        "---\npr_url: https://github.com/acme/app/pull/42\n---\n"
      )
      green_runner = StubRunner.new(
        Hive::Stages::Review::CiFix::Run.new("green", 0), settled_head: head
      )
      green = Hive::Stages::Review::RemoteCi.run!(
        task: task, cfg: cfg, ctx: ctx, runner: green_runner
      )
      assert_equal :green, green.status
      assert_equal 1, green_runner.calls.length
      assert_equal head, Hive::Gh.pr_frontmatter(File.join(task.folder, "pr.md"))["head_oid"]

      match = Hive::Stages::Review::FixGuardrail::Match.new(
        pattern_name: "ci_workflow_edit", file: ".github/workflows/ci.yml",
        line: 1, snippet: "workflow", severity: :high, match_sha256: "a" * 64
      )
      guardrail = Hive::Stages::Review::FixGuardrail::Result.new(
        status: :tripped, matches: [ match ], waived_matches: []
      )
      blocked_runner = StubRunner.new(
        Hive::Stages::Review::CiFix::CommandError.new("blocked"),
        guardrail_result: guardrail
      )
      blocked = Hive::Stages::Review::RemoteCi.run!(
        task: task, cfg: cfg, ctx: ctx, runner: blocked_runner
      )
      assert_equal :guardrail, blocked.status
      assert_same guardrail, blocked.guardrail
      assert_equal 1, blocked.attempts
    end
  end

  def test_run_converts_io_failures_to_a_typed_error
    with_fixture do |_repo, _head, task, ctx, _gh, _clock, _runner|
      File.write(File.join(task.folder, "pr.md"), "---\npr_url: x\n---\n")
      with_replaced_singleton_method(
        Hive::Gh, :pr_frontmatter, ->(*) { raise IOError, "disk unavailable" }
      ) do
        result = Hive::Stages::Review::RemoteCi.run!(task: task, cfg: cfg, ctx: ctx)
        assert_equal :error, result.status
        assert_equal 0, result.attempts
        assert_match(/disk unavailable/, result.error_message)
      end
    end
  end

  def test_runner_waits_for_named_and_status_context_checks_to_settle
    with_fixture do |_repo, head, _task, _ctx, gh, _clock, runner|
      checks = [
        check,
        { "context" => "legacy", "state" => "SUCCESS", "targetUrl" => "" }
      ]
      gh.rollups = Array.new(4) { rollup(head: head, checks: checks) }

      result = runner.call(max_bytes: 1_024, timeout_sec: 5)

      assert_equal 0, result.exit_code
      assert_equal "GitHub checks for the exact pull-request head", runner.command_label
      assert_includes result.combined, head
      assert_equal 1, gh.pushes.length
      assert_equal head, gh.pushes.first.last.fetch(:expected_remote_oid)
      assert_equal false, gh.pushes.first.last.fetch(:set_upstream)
      assert_operator gh.rollup_calls, :>=, 3
    end
  end

  def test_runner_allows_an_intentionally_checkless_pr_after_grace
    with_fixture do |_repo, head, _task, _ctx, gh, clock, runner|
      gh.rollups = Array.new(4) { rollup(head: head, checks: []) }

      result = runner.call(max_bytes: 1_024, timeout_sec: 5)

      assert_equal 0, result.exit_code
      assert_operator clock.now, :>=, 2
    end
  end

  def test_runner_returns_failure_logs_for_the_exact_failed_head
    with_fixture do |_repo, head, _task, _ctx, gh, _clock, runner|
      failed = check(
        conclusion: "FAILURE",
        detailsUrl: "https://github.com/acme/app/actions/runs/1/job/99"
      )
      gh.rollups = [ rollup(head: head, checks: [ failed ]), rollup(head: head, checks: [ failed ]) ]
      gh.jobs = [ { "name" => "unit", "log" => "expected 1, got 2" } ]

      result = runner.call(max_bytes: 1_024, timeout_sec: 5)

      assert_equal 1, result.exit_code
      assert_includes result.combined, "## unit"
      assert_includes result.combined, "expected 1"
    end
  end

  def test_runner_formats_status_failure_without_job_logs_and_caps_output
    with_fixture do |_repo, head, _task, _ctx, gh, _clock, runner|
      failed = {
        "context" => "legacy", "state" => "FAILURE",
        "targetUrl" => "https://ci.example.test/result/" + ("x" * 200)
      }
      gh.rollups = [ rollup(head: head, checks: [ failed ]), rollup(head: head, checks: [ failed ]) ]

      result = runner.call(max_bytes: 40, timeout_sec: 5)

      assert_equal 1, result.exit_code
      assert_operator result.combined.bytesize, :<=, 40
    end
  end

  def test_runner_times_out_when_baseline_checks_never_appear_on_exact_head
    with_fixture do |_repo, head, _task, _ctx, gh, _clock, runner|
      gh.rollups = [
        rollup(head: head, checks: [ check(name: "unit"), check(name: "lint") ])
      ] + Array.new(6) { rollup(head: head, checks: [ check(name: "unit") ]) }

      result = runner.call(max_bytes: 1_024, timeout_sec: 3)

      assert_instance_of Hive::Stages::Review::CiFix::CommandError, result
      assert_match(/did not settle/, result.reason)
    end
  end

  def test_runner_reports_an_exact_head_failure_at_the_settlement_deadline
    with_fixture do |_repo, head, _task, _ctx, gh, _clock, runner|
      gh.rollups = [
        rollup(head: head, checks: [ check(name: "unit"), check(name: "lint") ]),
        rollup(
          head: head,
          checks: [ check(name: "unit", status: "PENDING", conclusion: "") ]
        ),
        rollup(
          head: head,
          checks: [ check(name: "unit", conclusion: "FAILURE") ]
        )
      ]

      result = runner.call(max_bytes: 1_024, timeout_sec: 1)

      assert_equal 1, result.exit_code
      assert_includes result.combined, "unit: FAILURE"
    end
  end

  def test_runner_does_not_repair_failures_from_a_different_head
    with_fixture do |_repo, head, _task, _ctx, gh, _clock, runner|
      other = "b" * 40
      gh.rollups = [ rollup(head: head, checks: [ check ]) ] +
                   Array.new(5) do
                     rollup(head: other, checks: [ check(conclusion: "FAILURE") ])
                   end

      result = runner.call(max_bytes: 1_024, timeout_sec: 2)

      assert_instance_of Hive::Stages::Review::CiFix::CommandError, result
      assert_match(/exact head/, result.reason)
    end
  end

  def test_runner_rejects_identity_drift_and_push_failure
    with_fixture do |_repo, head, _task, _ctx, gh, _clock, runner|
      gh.rollups = [ rollup(head: "b" * 40, checks: [ check ]) ]
      drift = runner.call(max_bytes: 1_024, timeout_sec: 2)
      assert_match(/head changed/, drift.reason)

      gh.metadata = gh.metadata.with(head_ref_oid: head)
      gh.rollups = [ rollup(head: head, checks: [ check ]) ]
      gh.push_result = Hive::Gh::PushResult.new(
        success: false, stdout: "push stdout", stderr: "push rejected"
      )
      rejected = runner.call(max_bytes: 1_024, timeout_sec: 2)
      assert_match(/push rejected/, rejected.reason)
    end
  end

  def test_runner_guardrails_ci_repair_before_publication
    with_fixture do |repo, head, task, ctx, gh, clock, _runner|
      FileUtils.mkdir_p(File.join(repo, ".github", "workflows"))
      File.write(File.join(repo, ".github", "workflows", "ci.yml"), "name: changed\n")
      run!("git", "-C", repo, "add", ".github/workflows/ci.yml")
      run!("git", "-C", repo, "commit", "-m", "unsafe ci repair", "--quiet")
      new_head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      gh.rollups = [ rollup(head: head, checks: [ check ]) ]
      guarded = Hive::Stages::Review::RemoteCi::Runner.new(
        task: task, cfg: cfg, ctx: ctx,
        pr_url: "https://github.com/acme/app/pull/42", gh: gh,
        publication_base_head: head,
        clock: -> { clock.now }, sleeper: ->(seconds) { clock.now += seconds },
        poll_interval_sec: 1, quiet_settlement_sec: 1, no_checks_grace_sec: 1
      )

      result = guarded.call(max_bytes: 1_024, timeout_sec: 3)

      assert_instance_of Hive::Stages::Review::CiFix::CommandError, result
      assert_match(/guardrail approval/, result.reason)
      assert_equal :tripped, guarded.guardrail_result.status
      assert_equal new_head, run!("git", "-C", repo, "rev-parse", "HEAD").strip
      assert_empty gh.pushes
    end
  end

  def test_runner_allows_a_clean_ci_repair_then_publishes_with_a_lease
    with_fixture do |repo, head, task, ctx, gh, clock, _runner|
      FileUtils.mkdir_p(File.join(repo, "lib"))
      File.write(File.join(repo, "lib", "repair.rb"), "REPAIRED = true\n")
      run!("git", "-C", repo, "add", "lib/repair.rb")
      run!("git", "-C", repo, "commit", "-m", "safe ci repair", "--quiet")
      new_head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      gh.rollups = [ rollup(head: head, checks: [ check ]) ] +
                   Array.new(3) { rollup(head: new_head, checks: [ check ]) }
      guarded = Hive::Stages::Review::RemoteCi::Runner.new(
        task: task, cfg: cfg, ctx: ctx,
        pr_url: "https://github.com/acme/app/pull/42", gh: gh,
        publication_base_head: head,
        clock: -> { clock.now }, sleeper: ->(seconds) { clock.now += seconds },
        poll_interval_sec: 1, quiet_settlement_sec: 1, no_checks_grace_sec: 1
      )

      result = guarded.call(max_bytes: 1_024, timeout_sec: 3)

      assert_equal 0, result.exit_code
      assert_nil guarded.guardrail_result
      assert_equal head, gh.pushes.first.last.fetch(:expected_remote_oid)
    end
  end

  def test_runner_rejects_invalid_or_foreign_pr_identity
    with_fixture do |_repo, head, _task, _ctx, gh, _clock, runner|
      invalid = Hive::Stages::Review::RemoteCi::Runner.new(
        task: runner.instance_variable_get(:@task), cfg: cfg,
        ctx: runner.instance_variable_get(:@ctx), pr_url: "not-a-pr", gh: gh
      ).call(max_bytes: 10, timeout_sec: 1)
      assert_match(/invalid pull-request URL/, invalid.reason)

      gh.identity = { "host" => "github.com", "repository" => "other/repo" }
      foreign = runner.call(max_bytes: 10, timeout_sec: 1)
      assert_match(/outside the task repository/, foreign.reason)

      gh.identity = { "host" => "github.com", "repository" => "acme/app" }
      gh.metadata = gh.metadata.with(state: "CLOSED")
      stale = runner.call(max_bytes: 10, timeout_sec: 1)
      assert_match(/identity is stale/, stale.reason)

      gh.metadata = gh.metadata.with(state: "OPEN", head_ref_oid: head)
      gh.candidates = []
      ambiguous = runner.call(max_bytes: 10, timeout_sec: 1)
      assert_match(/one open pull request/, ambiguous.reason)

      gh.candidates = [
        {
          "number" => 42, "url" => "https://github.com/acme/app/pull/42",
          "state" => "OPEN", "headRefName" => "demo-task"
        }
      ]
      gh.metadata = gh.metadata.with(head_ref_oid: "")
      missing_oid = runner.call(max_bytes: 10, timeout_sec: 1)
      assert_match(/head OID is unavailable/, missing_oid.reason)
    end
  end

  def test_runner_rejects_owned_worktree_mismatch_and_missing_head
    with_fixture do |repo, _head, task, ctx, gh, _clock, runner|
      with_replaced_singleton_method(
        Hive::Worktree, :read_owned_pointer,
        ->(*, **) { { "path" => File.dirname(repo), "branch" => task.slug } }
      ) do
        mismatch = runner.call(max_bytes: 10, timeout_sec: 1)
        assert_match(/owned worktree/, mismatch.reason)
      end

      bad_ctx = ctx.with(worktree_path: File.join(repo, "README.md"))
      with_replaced_singleton_method(
        Hive::Worktree, :read_owned_pointer,
        ->(*, **) { { "path" => bad_ctx.worktree_path, "branch" => task.slug } }
      ) do
        missing = Hive::Stages::Review::RemoteCi::Runner.new(
          task: task, cfg: cfg, ctx: bad_ctx,
          pr_url: "https://github.com/acme/app/pull/42", gh: gh
        ).call(max_bytes: 10, timeout_sec: 1)
        assert_match(/HEAD is unavailable/, missing.reason)
      end
    end
  end

  def test_runner_rejects_bad_rollup_identity_and_unknown_check_state
    with_fixture do |_repo, head, _task, _ctx, gh, _clock, runner|
      gh.rollups = [
        rollup(
          head: head, checks: [ check ],
          url: "https://github.com/acme/other/pull/42"
        )
      ]
      wrong = runner.call(max_bytes: 10, timeout_sec: 1)
      assert_match(/different pull request/, wrong.reason)

      gh.rollups = [ rollup(head: "", checks: [ check ]) ]
      missing_head = runner.call(max_bytes: 10, timeout_sec: 1)
      assert_match(/omitted the pull-request head OID/, missing_head.reason)

      unknown = check(status: "COMPLETED", conclusion: "MYSTERY")
      gh.rollups = [ rollup(head: head, checks: [ unknown ]), rollup(head: head, checks: [ unknown ]) ]
      failed = runner.call(max_bytes: 10, timeout_sec: 1)
      assert_equal 1, failed.exit_code
    end
  end

  def test_runner_default_clock_and_sleeper_are_callable
    with_fixture do |_repo, _head, task, ctx, gh, _clock, _runner|
      runner = Hive::Stages::Review::RemoteCi::Runner.new(
        task: task, cfg: cfg, ctx: ctx,
        pr_url: "https://github.com/acme/app/pull/42", gh: gh
      )

      assert_kind_of Numeric, runner.instance_variable_get(:@clock).call
      assert_equal 0, runner.instance_variable_get(:@sleeper).call(0)
    end
  end
end
