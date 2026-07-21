require "test_helper"
require "hive/draft_pr_receipt"
require "hive/stages/agent_report"
require "hive/stages/agent_worktree"
require "hive/stages/draft_pr_handoff"

class StagesDraftPrHandoffTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(:folder, :slug, :project_root, keyword_init: true)
  VALID_REPORT = StagesAgentReportTest::VALID_REPORT rescue <<~REPORT.freeze
    Decision: ready

    Reproduction:
    Reproduced the failing request locally.

    Cause:
    The response mapper discarded nil values.

    Changes:
    Preserve the response key and add a regression test.

    Tests:
    bundle exec ruby -Itest test/example_test.rb (pass)

    Risks:
    Low; the change is limited to one mapper.

    Suggested PR title: Preserve nil response values
  REPORT

  def test_exact_normal_path_is_terminal_and_idempotent
    with_handoff_fixture do |fixture|
      calls = fixture.fetch(:calls)
      result = run_handoff(fixture)

      assert_equal "pr-opened", result.fetch(:outcome)
      assert_equal fixture.fetch(:pr_url), result.fetch(:pr_url)
      assert_equal 1, calls.count { |call| call.first == :push }
      assert_equal 1, calls.count { |call| call.first == :create }
      push = calls.find { |call| call.first == :push }
      assert_equal fixture.fetch(:head), push[1]

      receipt = read_receipt(fixture)
      assert_equal "terminal", receipt.fetch("phase")
      assert_equal "pr-opened", receipt.fetch("terminal_outcome")
      assert_equal fixture.fetch(:head), receipt.fetch("observed_remote_oid")
      assert_equal fixture.fetch(:pr_url), Hive::Gh.pr_frontmatter(File.join(fixture.fetch(:task).folder, "pr.md"))["pr_url"]
      assert_equal :complete, Hive::Markers.current(File.join(fixture.fetch(:task).folder, "fix-report.md")).name

      again = run_handoff(fixture)
      assert_equal "pr-opened", again.fetch(:outcome)
      assert_equal 1, calls.count { |call| call.first == :push }
      assert_equal 1, calls.count { |call| call.first == :create }
    end
  end

  def test_clean_no_fix_terminates_without_remote_work_and_requests_explicit_cleanup
    with_handoff_fixture do |fixture|
      run!("git", "-C", fixture.fetch(:repo), "reset", "--hard", fixture.fetch(:base), "--quiet")
      source = VALID_REPORT.sub("Decision: ready", "Decision: no-fix")
      fixture[:report_source] = source
      fixture[:report] = Hive::Stages::AgentReport.parse(source)
      fixture[:state] = Hive::Stages::AgentReport.validate_repository!(
        fixture.fetch(:report), fixture.fetch(:context)
      )
      File.write(File.join(fixture.fetch(:task).folder, "fix-report.md"), source)
      cleaned = []
      cleanup = ->(task, context) { cleaned << [ task.slug, context.worktree_path ] }

      with_replaced_singleton_method(Hive::Stages::DraftPrHandoff, :cleanup_no_fix_worktree, cleanup) do
        result = run_handoff(fixture)
        assert_equal "no-fix", result.fetch(:outcome)
      end
      assert_equal [ [ "fix-task", fixture.fetch(:repo) ] ], cleaned
      assert_equal "no-fix", read_receipt(fixture).fetch("terminal_outcome")
      assert_empty fixture.fetch(:calls).select { |call| %i[push create].include?(call.first) }
    end
  end

  def test_create_failure_records_one_attempt_and_recovers_by_observation_without_second_create
    with_handoff_fixture(create_visible: false) do |fixture|
      first = run_handoff(fixture)
      assert_equal :error, first.fetch(:status)
      assert_equal "pr_create_intent", read_receipt(fixture).fetch("phase")
      assert_equal 1, fixture.fetch(:calls).count { |call| call.first == :create }
      marker = Hive::Markers.current(File.join(fixture.fetch(:task).folder, "fix-report.md"))
      assert_equal "draft_pr_handoff_failed", marker.attrs.fetch("reason")

      fixture.fetch(:remote)[:prs] = [ fixture.fetch(:pr) ]
      source = Hive::Stages::DraftPrHandoff.report_source_for_resume(
        File.join(fixture.fetch(:task).folder, "fix-report.md"),
        expected_sha256: read_receipt(fixture).fetch("report_sha256")
      )
      result = run_handoff(fixture, report_source: source)
      assert_equal "pr-opened", result.fetch(:outcome)
      assert_equal 1, fixture.fetch(:calls).count { |call| call.first == :create }
    end
  end

  def test_exact_pr_appearing_after_create_intent_is_adopted_without_create_attempt
    with_handoff_fixture do |fixture|
      fixture.fetch(:remote)[:pr_visible_on_lookup] = 4

      result = run_handoff(fixture)

      assert_equal "pr-opened", result.fetch(:outcome)
      assert_empty fixture.fetch(:calls).select { |call| call.first == :create }
      receipt = read_receipt(fixture)
      assert_equal "terminal", receipt.fetch("phase")
      refute receipt.key?("pr_create_attempted_at")
    end
  end

  def test_secret_added_then_removed_and_binary_blob_are_quarantined_before_push
    with_handoff_fixture do |fixture|
      repo = fixture.fetch(:repo)
      token = "github_pat_#{'A' * 40}"
      File.write(File.join(repo, "temporary-secret.txt"), token)
      run!("git", "-C", repo, "add", "temporary-secret.txt")
      run!("git", "-C", repo, "commit", "-m", "temporary evidence", "--quiet")
      FileUtils.rm_f(File.join(repo, "temporary-secret.txt"))
      run!("git", "-C", repo, "add", "-u")
      run!("git", "-C", repo, "commit", "-m", "remove evidence", "--quiet")
      refresh_head!(fixture)

      result = run_handoff(fixture)
      assert_equal :error, result.fetch(:status)
      assert_equal "draft_pr_quarantined", read_receipt(fixture).fetch("error_reason")
      assert_empty fixture.fetch(:calls).select { |call| %i[push create].include?(call.first) }
      refute_includes File.read(File.join(fixture.fetch(:task).folder, "fix-report.md")), token
    end

    with_handoff_fixture do |fixture|
      File.binwrite(File.join(fixture.fetch(:repo), "image.bin"), "abc\0def")
      run!("git", "-C", fixture.fetch(:repo), "add", "image.bin")
      run!("git", "-C", fixture.fetch(:repo), "commit", "-m", "binary", "--quiet")
      refresh_head!(fixture)

      result = run_handoff(fixture)
      assert_equal "draft_pr_quarantined", read_receipt(fixture).fetch("error_reason")
      assert_equal :error, result.fetch(:status)
    end
  end

  def test_oversized_blob_is_quarantined_before_push
    with_handoff_fixture do |fixture|
      File.binwrite(
        File.join(fixture.fetch(:repo), "oversized.txt"),
        "a" * (Hive::Stages::DraftPrHandoff::MAX_OBJECT_BYTES + 1)
      )
      run!("git", "-C", fixture.fetch(:repo), "add", "oversized.txt")
      run!("git", "-C", fixture.fetch(:repo), "commit", "-m", "oversized evidence", "--quiet")
      refresh_head!(fixture)

      result = run_handoff(fixture)

      assert_equal :error, result.fetch(:status)
      assert_equal "draft_pr_quarantined", read_receipt(fixture).fetch("error_reason")
      assert_empty fixture.fetch(:calls).select { |call| %i[push create].include?(call.first) }
    end
  end

  def test_remote_drift_and_unowned_pr_block_without_mutation
    with_handoff_fixture do |fixture|
      fixture.fetch(:remote)[:task_oid] = "f" * 40
      result = run_handoff(fixture)
      assert_equal :error, result.fetch(:status)
      assert_equal "draft_pr_identity_blocked", read_receipt(fixture).fetch("error_reason")
      assert_empty fixture.fetch(:calls).select { |call| %i[push create].include?(call.first) }
    end

    with_handoff_fixture do |fixture|
      fixture.fetch(:remote)[:prs] = [ fixture.fetch(:pr) ]
      result = run_handoff(fixture)
      assert_equal :error, result.fetch(:status)
      assert_equal "draft_pr_identity_blocked", read_receipt(fixture).fetch("error_reason")
      assert_empty fixture.fetch(:calls).select { |call| %i[push create].include?(call.first) }
    end
  end

  def test_auth_loss_is_recoverable_and_does_not_consume_mutation_intent
    with_handoff_fixture do |fixture|
      fixture.fetch(:remote)[:auth_error] = true
      result = run_handoff(fixture)

      assert_equal :error, result.fetch(:status)
      assert_equal "agent_validated", read_receipt(fixture).fetch("phase")
      marker = Hive::Markers.current(File.join(fixture.fetch(:task).folder, "fix-report.md"))
      assert_equal "draft_pr_handoff_failed", marker.attrs.fetch("reason")
      assert_empty fixture.fetch(:calls).select { |call| %i[push create].include?(call.first) }
    end
  end

  def test_multiple_closed_and_mismatched_prs_block_without_corrective_mutation
    variants = [
      lambda { |fixture| [ fixture.fetch(:pr), fixture.fetch(:pr).merge("number" => 8, "url" => "https://github.com/acme/widgets/pull/8") ] },
      lambda { |fixture| [ fixture.fetch(:pr).merge("state" => "CLOSED") ] },
      lambda { |fixture| [ fixture.fetch(:pr).merge("baseRefName" => "release") ] }
    ]
    variants.each do |build|
      with_handoff_fixture do |fixture|
        fixture.fetch(:remote)[:prs] = build.call(fixture)
        result = run_handoff(fixture)
        assert_equal :error, result.fetch(:status)
        assert_equal "draft_pr_identity_blocked", read_receipt(fixture).fetch("error_reason")
        assert_empty fixture.fetch(:calls).select { |call| %i[push create].include?(call.first) }
      end
    end
  end

  def test_report_secret_is_redacted_when_handoff_is_quarantined
    with_handoff_fixture do |fixture|
      token = "github_pat_#{'Z' * 40}"
      source = VALID_REPORT.sub("Low; the change is limited to one mapper.", "Leaked #{token}")
      fixture[:report_source] = source
      fixture[:report] = Hive::Stages::AgentReport.parse(source)
      File.write(File.join(fixture.fetch(:task).folder, "fix-report.md"), source)

      result = run_handoff(fixture)
      assert_equal :error, result.fetch(:status)
      persisted = File.read(File.join(fixture.fetch(:task).folder, "fix-report.md"))
      refute_includes persisted, token
      assert_includes persisted, "[REDACTED:github_fine_grained_pat]"
      assert_equal 0o600, File.stat(File.join(fixture.fetch(:task).folder, "fix-report.md")).mode & 0o777
    end
  end

  def test_terminal_resume_repairs_missing_controller_artifacts_without_remote_mutation
    with_handoff_fixture do |fixture|
      result = run_handoff(fixture)
      assert_equal "pr-opened", result.fetch(:outcome)
      calls = fixture.fetch(:calls).length
      FileUtils.rm_f(File.join(fixture.fetch(:task).folder, "pr.md"))
      Hive::Markers.clear_current(
        File.join(fixture.fetch(:task).folder, "fix-report.md"),
        expected_name: :complete, purge_history: true
      )

      receipt = read_receipt(fixture)
      resumed = Hive::Stages::DraftPrHandoff.resume_terminal!(fixture.fetch(:task), receipt)
      assert_equal "pr-opened", resumed.fetch(:outcome)
      assert File.exist?(File.join(fixture.fetch(:task).folder, "pr.md"))
      assert_equal :complete, Hive::Markers.current(File.join(fixture.fetch(:task).folder, "fix-report.md")).name
      assert_equal calls, fixture.fetch(:calls).length
    end
  end

  def test_projection_redacts_personal_environment_identifiers_and_default_deny_argv
    report = Hive::Stages::AgentReport.parse(
      VALID_REPORT
        .sub("Reproduced the failing request locally.", "Seen by dev@example.com in /home/dev/private.log at https://internal.example.test/a")
    )
    projected = Hive::Stages::DraftPrHandoff.send(:project_report, report)
    refute_includes projected.body, "dev@example.com"
    refute_includes projected.body, "/home/dev"
    refute_includes projected.body, "internal.example.test"

    calls = []
    capture = lambda do |*argv, **_kwargs|
      calls << argv
      [ "https://github.com/acme/widgets/pull/7\n", "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
    end
    with_replaced_singleton_method(Hive::Gh, :capture3, capture) do
      Dir.mktmpdir("draft-pr-body", "/dev/shm") do |dir|
        Hive::Gh.create_draft_pr(
          dir, repository: "acme/widgets", host: "github.com",
          head: "fix-task", base: "main", title: "Fix it", body: "Safe body", cfg: {}
        )
      end
    end
    argv = calls.fetch(0)
    assert_includes argv, "--draft"
    assert_includes argv, "--body-file"
    refute_includes argv, "Safe body"
    forbidden = %w[--force --force-with-lease ready merge close edit release publish deploy]
    forbidden.each { |word| refute_includes argv, word }
    body_path = argv.fetch(argv.index("--body-file") + 1)
    refute File.exist?(body_path), "temporary PR body must be removed"
  end

  private

  def with_handoff_fixture(create_visible: true)
    Dir.mktmpdir("draft-pr-handoff", "/dev/shm") do |root|
      repo = File.join(root, "worktree", "fix-task")
      task_folder = File.join(root, "task")
      FileUtils.mkdir_p([ repo, task_folder ])
      run!("git", "-C", repo, "init", "--quiet", "--initial-branch=main")
      run!("git", "-C", repo, "config", "user.email", "test@example.com")
      run!("git", "-C", repo, "config", "user.name", "Hive Test")
      run!("git", "-C", repo, "remote", "add", "origin", "git@github.com:acme/widgets.git")
      File.write(File.join(repo, "app.rb"), "before\n")
      run!("git", "-C", repo, "add", "app.rb")
      run!("git", "-C", repo, "commit", "-m", "base", "--quiet")
      base = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      run!("git", "-C", repo, "switch", "-c", "fix-task", "--quiet")
      File.write(File.join(repo, "app.rb"), "after\n")
      run!("git", "-C", repo, "add", "app.rb")
      run!("git", "-C", repo, "commit", "-m", "fix response", "--quiet")
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip

      task = TaskStub.new(folder: task_folder, slug: "fix-task", project_root: repo)
      context = Hive::Stages::AgentWorktree::Context.new(
        worktree_path: repo, task_branch: "fix-task", base_branch: "main",
        base_oid: base, repository: "github.com/acme/widgets"
      )
      initialize_receipt!(task, context)
      File.write(File.join(task_folder, "fix-report.md"), VALID_REPORT)
      report = Hive::Stages::AgentReport.parse(VALID_REPORT)
      state = Hive::Stages::AgentReport.validate_repository!(report, context)
      pr_url = "https://github.com/acme/widgets/pull/7"
      pr = {
        "number" => 7, "url" => pr_url, "state" => "OPEN", "isDraft" => true,
        "headRefName" => "fix-task", "headRefOid" => head,
        "baseRefName" => "main", "baseRefOid" => base,
        "headRepository" => { "nameWithOwner" => "acme/widgets" }
      }
      remote = { task_oid: nil, prs: [] }
      calls = []
      fixture = {
        root: root, repo: repo, task: task, context: context, report: report,
        state: state, report_source: VALID_REPORT, base: base, head: head,
        pr_url: pr_url, pr: pr, remote: remote, calls: calls,
        create_visible: create_visible
      }
      with_fake_remote(fixture) { yield fixture }
    end
  end

  def with_fake_remote(fixture)
    remote = fixture.fetch(:remote)
    calls = fixture.fetch(:calls)
    context = fixture.fetch(:context)
    auth = lambda do |*_args, **_kwargs|
      calls << [ :auth ]
      raise Hive::GhError, "auth denied" if remote[:auth_error]
    end
    identity = ->(_path, cfg: nil) { { "host" => "github.com", "repository" => "acme/widgets" } }
    capture = lambda do |*argv, **_kwargs|
      if argv[0, 6] == [ "git", "-C", context.worktree_path, "remote", "get-url", "--all" ]
        [ "git@github.com:acme/widgets.git\n", "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
      else
        raise "default-deny capture3: #{argv.inspect}"
      end
    end
    remote_oid = lambda do |_path, branch, **_kwargs|
      branch == "main" ? fixture.fetch(:base) : remote[:task_oid]
    end
    lookup = lambda do |*_args, **_kwargs|
      remote[:lookup_count] = remote.fetch(:lookup_count, 0) + 1
      if remote[:pr_visible_on_lookup] == remote[:lookup_count]
        remote[:prs] = [ fixture.fetch(:pr) ]
      end
      remote[:prs].map(&:dup)
    end
    push = lambda do |_path, oid, branch, **_kwargs|
      calls << [ :push, oid, branch ]
      remote[:task_oid] = oid
      Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")
    end
    create = lambda do |_path, **_kwargs|
      calls << [ :create ]
      remote[:prs] = [ fixture.fetch(:pr) ] if fixture.fetch(:create_visible)
      [ fixture.fetch(:pr_url), "", Hive::Gh::CommandStatus.new(exitstatus: fixture.fetch(:create_visible) ? 0 : 1) ]
    end

    with_replaced_singleton_method(Hive::Gh, :ensure_authenticated!, auth) do
      with_replaced_singleton_method(Hive::Gh, :repository_identity, identity) do
        with_replaced_singleton_method(Hive::Gh, :capture3, capture) do
          with_replaced_singleton_method(Hive::Gh, :remote_branch_oid, remote_oid) do
            with_replaced_singleton_method(Hive::Gh, :lookup_prs_for_branch, lookup) do
              with_replaced_singleton_method(Hive::Gh, :push_exact_oid, push) do
                with_replaced_singleton_method(Hive::Gh, :create_draft_pr, create) { yield }
              end
            end
          end
        end
      end
    end
  end

  def run_handoff(fixture, report_source: fixture.fetch(:report_source))
    Hive::Stages::DraftPrHandoff.run!(
      fixture.fetch(:task), context: fixture.fetch(:context),
      report: fixture.fetch(:report), repository_state: fixture.fetch(:state),
      report_source: report_source, cfg: {}
    )
  end

  def initialize_receipt!(task, context)
    Hive::DraftPrReceipt.initialize!(
      task.folder,
      expected: {
        "version" => 1, "phase" => "worktree_created",
        "repository" => context.repository, "base_branch" => context.base_branch,
        "base_oid" => context.base_oid, "task_branch" => context.task_branch,
        "worktree_path" => context.worktree_path
      },
      worktree_root: File.dirname(context.worktree_path)
    )
  end

  def read_receipt(fixture)
    Hive::DraftPrReceipt.read(
      fixture.fetch(:task).folder,
      worktree_root: File.dirname(fixture.fetch(:context).worktree_path)
    )
  end

  def refresh_head!(fixture)
    head = run!("git", "-C", fixture.fetch(:repo), "rev-parse", "HEAD").strip
    fixture[:head] = head
    fixture[:state] = Hive::Stages::AgentReport.validate_repository!(
      fixture.fetch(:report), fixture.fetch(:context)
    )
    fixture.fetch(:pr)["headRefOid"] = head
  end
end
