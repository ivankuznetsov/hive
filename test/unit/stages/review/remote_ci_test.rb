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
        head_ref_oid: remote_head, is_cross_repository: false, state: "OPEN", is_draft: nil
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

    def origin_push_url(*) = "https://github.com/acme/app.git"
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
      run!("git", "-C", repo, "checkout", "-b", "demo-task", "--quiet")
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
          test_case = self
          gate = lambda do |repository_path:, branch:, expected_remote_oid:, expected_local_oid:|
            gh.pushes << [ repository_path, branch, { expected_remote_oid: expected_remote_oid } ]
            raise Hive::AgentGitGate::RemoteConflict unless gh.push_result.success?
            test_case.assert_equal expected_local_oid, Hive::ReviewPublicationRecovery.git(repo, "rev-parse", "HEAD").strip
            current = test_case.run!("git", "-C", repo, "rev-parse", "HEAD").strip
            gh.metadata = gh.metadata.with(head_ref_oid: current)
            Struct.new(:after_oid).new(current)
          end
          with_replaced_singleton_method(Hive::AgentGitGate, :publish_local_branch, gate) do
            yield(repo, head, task, ctx, gh, clock, runner)
          end
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

  # hivedev's bin/ci posts a `signoff` commit status for a commit already on
  # the remote. Review runs it before publishing the new head, so the status
  # exists only on the old head and must not hold the new head pending.
  def test_runner_does_not_wait_for_baseline_commit_statuses_on_a_new_head
    with_fixture do |_repo, head, _task, _ctx, gh, _clock, runner|
      signoff = { "__typename" => "StatusContext", "context" => "signoff", "state" => "FAILURE", "targetUrl" => "" }
      legacy = { "context" => "legacy", "state" => "SUCCESS", "targetUrl" => "" }
      gh.rollups = [ rollup(head: head, checks: [ signoff, legacy, check(name: "unit") ]) ] +
                   Array.new(6) { rollup(head: head, checks: [ check(name: "unit") ]) }

      result = runner.call(max_bytes: 1_024, timeout_sec: 5)

      assert_equal 0, result.exit_code, result.respond_to?(:reason) ? result.reason : nil
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
      assert_match(/remote_conflict/, rejected.reason)
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

  def test_verification_recipe_uses_the_registered_project_alias
    with_fixture do |repo, head, task, ctx, gh, _clock, _runner|
      registration = -> { [ { "name" => "registered-alias", "path" => repo } ] }
      with_replaced_singleton_method(Hive::Config, :registered_projects, registration) do
        result = Hive::Stages::Review::Publication.new(task: task, cfg: cfg, ctx: ctx,
          pr_url: gh.metadata.url, gh: gh).publish!(expected_head: head)
        assert_includes result.evidence["verification_recipe"], "registered-alias:demo-task"
        assert_equal "published", result.evidence["publication"]
      end
    end
  end

  def test_withheld_publication_rejects_a_context_outside_the_owned_worktree
    with_fixture do |_repo, head, task, ctx, gh, _clock, _runner|
      Dir.mktmpdir do |other|
        publisher = Hive::Stages::Review::Publication.new(task: task, cfg: cfg,
          ctx: ctx.with(worktree_path: other), pr_url: gh.metadata.url, gh: gh)
        publisher.publish!(expected_head: head, withheld: "guardrail_approval_required")
        assert_equal "unknown", publisher.evidence["publication"]
        assert_equal "publication_identity_unavailable", publisher.evidence["failure_reason"]
        assert_empty gh.pushes
      end
    end
  end

  def test_confirmation_rejects_pr_identity_movement_even_at_the_same_head
    with_fixture do |_repo, head, task, ctx, gh, _clock, _runner|
      publisher = Hive::Stages::Review::Publication.new(task: task, cfg: cfg, ctx: ctx,
        pr_url: gh.metadata.url, gh: gh).publish!(expected_head: head)
      identity = publisher.identity.merge(number: 43)
      publisher.define_singleton_method(:resolve_identity!) { identity }
      error = assert_raises(Hive::Stages::Review::Publication::Stop) { publisher.confirm!(head) }
      assert_equal "pr_identity_moved", error.reason
      assert_equal "published", publisher.evidence["publication"]
    end
  end

  def test_project_registration_failure_retains_publication_but_omits_retry_recipe
    with_fixture do |_repo, head, task, ctx, gh, _clock, _runner|
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { raise Hive::ConfigError, "unreadable" }) do
        publisher = Hive::Stages::Review::Publication.new(task: task, cfg: cfg, ctx: ctx,
          pr_url: gh.metadata.url, gh: gh).publish!(expected_head: head)
        assert_equal "published", publisher.evidence["publication"]
        assert_equal "project_registration_unavailable", publisher.evidence["recovery_reason"]
        assert_nil publisher.evidence["verification_recipe"]
      end
    end
  end

  def test_receipt_confirmed_publication_detects_local_head_movement_without_retry
    with_fixture do |repo, head, task, ctx, gh, _clock, _runner|
      calls = 0
      test_case = self
      gate = Object.new
      gate.define_singleton_method(:publish_local_branch) do |**|
        calls += 1
        test_case.run!("git", "-C", repo, "commit", "--allow-empty", "-qm", "concurrent movement")
        Struct.new(:after_oid).new(head)
      end
      result = Hive::Stages::Review::Publication.new(task: task, cfg: cfg, ctx: ctx,
        pr_url: gh.metadata.url, gh: gh, gate: gate).publish!(expected_head: head)
      assert_equal "published", result.evidence["publication"]
      assert_equal "local_head_moved", result.evidence["failure_reason"]
      assert_equal 1, calls
    end
  end

  def test_cross_repository_and_merged_pr_refuse_publication
    with_fixture do |_repo, head, task, ctx, gh, _clock, _runner|
      [ gh.metadata.with(is_cross_repository: true), gh.metadata.with(state: "MERGED") ].each do |metadata|
        gh.metadata = metadata
        result = Hive::Stages::Review::Publication.new(task: task, cfg: cfg, ctx: ctx,
          pr_url: metadata.url, gh: gh).publish!(expected_head: head)
        assert_equal "unknown", result.evidence["publication"]
        assert_equal "publication_identity_unavailable", result.evidence["failure_reason"]
        assert_empty gh.pushes
      end
    end
  end

  def test_final_verification_settles_without_another_publication
    with_fixture do |_repo, head, task, ctx, gh, clock, _runner|
      gh.rollups = [ rollup(head: head, checks: [ check ]) ]
      runner = Hive::Stages::Review::RemoteCi::Runner.new(task: task, cfg: cfg, ctx: ctx,
        pr_url: gh.metadata.url, gh: gh, no_repair: true,
        clock: -> { clock.now }, sleeper: ->(seconds) { clock.now += seconds },
        poll_interval_sec: 1, quiet_settlement_sec: 1)
      assert_equal 0, runner.call(max_bytes: 1024, timeout_sec: 3).exit_code
      assert_empty gh.pushes
    end
  end

  def test_publication_receipt_survives_failed_pr_cross_check
    with_fixture do |_repo, head, task, ctx, gh, _clock, _runner|
      calls = 0
      metadata = gh.metadata
      gh.define_singleton_method(:pr_metadata) do |*|
        calls += 1
        raise Hive::GhError, "unavailable" if calls > 1
        metadata
      end
      result = Hive::Stages::Review::Publication.new(task: task, cfg: cfg, ctx: ctx,
        pr_url: metadata.url, gh: gh).publish!(expected_head: head)
      assert_equal "published", result.evidence["publication"]
      assert_equal "pending", result.evidence["verification"]
      assert_equal "pr_confirmation_unavailable", result.evidence["failure_reason"]
    end
  end

  def test_publication_failure_retains_multiple_commit_identifiers
    with_fixture do |repo, base, task, ctx, gh, _clock, _runner|
      shas = 2.times.map do |n|
        File.write(File.join(repo, "fix"), n.to_s)
        run!("git", "-C", repo, "add", "fix")
        run!("git", "-C", repo, "commit", "-qm", "fix #{n}")
        run!("git", "-C", repo, "rev-parse", "HEAD").strip
      end
      gate = Object.new
      gate.define_singleton_method(:publish_local_branch) { |**| raise Hive::AgentGitGate::PublicationFailed }
      gate.define_singleton_method(:observe_remote_branch) { |**| Struct.new(:oid).new(base) }
      result = Hive::Stages::Review::Publication.new(task: task, cfg: cfg, ctx: ctx,
        pr_url: gh.metadata.url, gh: gh, gate: gate).publish!(expected_head: shas.last)
      assert_equal "unpublished", result.evidence["publication"]
      assert_equal shas, result.evidence["unpushed_shas"]
      assert_includes result.evidence["push_command"], shas.last
      gate.define_singleton_method(:observe_remote_branch) { |**| raise Hive::AgentGitGate::CommandFailed }
      unknown = Hive::Stages::Review::Publication.new(task: task, cfg: cfg, ctx: ctx,
        pr_url: gh.metadata.url, gh: gh, gate: gate).publish!(expected_head: shas.last)
      assert_equal "unknown", unknown.evidence["publication"]
    end
  end

  def test_withholding_skips_hosted_ci_before_any_repair_or_publication
    with_fixture do |_repo, _head, task, ctx, _gh, _clock, _runner|
      runner = Object.new
      runner.define_singleton_method(:command_label) { raise "withheld CI must not start" }
      result = Hive::Stages::Review::RemoteCi.run!(task: task, cfg: cfg, ctx: ctx,
        runner: runner, publication_withheld: "fix_guardrail_receipt_required")
      assert_equal :skipped, result.status
      assert_equal 0, result.attempts
    end
  end

  def test_hosted_runner_cannot_publish_a_withheld_baseline
    with_fixture do |_repo, head, task, ctx, gh, _clock, _runner|
      gh.rollups = [ rollup(head: head, checks: [ check ]) ]
      runner = Hive::Stages::Review::RemoteCi::Runner.new(task: task, cfg: cfg, ctx: ctx,
        pr_url: gh.metadata.url, gh: gh, publication_base_head: head,
        publication_withheld: "fix_guardrail_receipt_required")
      result = runner.call(max_bytes: 1024, timeout_sec: 3)
      assert_match(/publication withheld/, result.reason)
      assert_empty gh.pushes
      assert_nil runner.settled_head
    end
  end

  def test_reused_publisher_does_not_carry_publication_proof_to_a_different_head
    [ :conflict, :unobservable, :identity_unavailable ].each do |failure|
      with_fixture do |repo, head, task, ctx, gh, _clock, _runner|
        publisher = Hive::Stages::Review::Publication.new(task: task, cfg: cfg, ctx: ctx,
          pr_url: gh.metadata.url, gh: gh).publish!(expected_head: head)
        assert_equal "published", publisher.evidence["publication"]
        run!("git", "-C", repo, "commit", "--allow-empty", "-qm", "next fix")
        new_head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
        gate = Object.new
        gate.define_singleton_method(:publish_local_branch) do |**|
          raise(failure == :conflict ? Hive::AgentGitGate::RemoteConflict : Hive::AgentGitGate::PublicationFailed)
        end
        gate.define_singleton_method(:observe_remote_branch) { |**| raise Hive::AgentGitGate::CommandFailed }
        publisher.instance_variable_set(:@gate, gate)
        gh.metadata = gh.metadata.with(state: "MERGED") if failure == :identity_unavailable
        publisher.publish!(expected_head: new_head)
        assert_equal new_head, publisher.evidence["local_head"]
        assert_equal "unknown", publisher.evidence["publication"], failure.to_s
        assert_equal "pending", publisher.evidence["verification"]
        refute_nil publisher.evidence["failure_reason"]
      end
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
