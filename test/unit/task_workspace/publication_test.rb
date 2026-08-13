require "test_helper"
require "rbconfig"
require "hive/task_workspace/publication"

class TaskWorkspacePublicationTest < Minitest::Test
  include HiveTestHelper

  def test_local_git_failures_scrub_absolute_paths_from_diagnostics
    with_task do |task|
      runner = lambda do |_argv, **_kwargs|
        status = Hive::TaskWorkspace::Publication::Status.new(success?: false, exitstatus: 128)
        [ "", "fatal: unsafe repository at /home/operator/private/demo", status, {} ]
      end
      panel = service(task, runner: runner).call

      serialized = JSON.generate(panel)
      refute_includes serialized, "/home/operator/private/demo"
      assert_includes serialized, "[REDACTED:path]"
    end
  end

  FakeTask = Data.define(:folder, :project_root, :slug)

  class FakeCache
    attr_reader :reads

    def initialize(result)
      @result = result
      @reads = []
    end

    def read(identity)
      @reads << identity
      @result
    end
  end

  class GitRunner
    attr_reader :commands

    def initialize(head: "d" * 40, branch: "demo", tracking: :pushed, dirty: false,
                   oversized: false)
      @head = head
      @branch = branch
      @tracking = tracking
      @dirty = dirty
      @oversized = oversized
      @commands = []
    end

    def call(argv, max_bytes:, **)
      path_index = argv.index("-C")
      path = argv.fetch(path_index + 1)
      args = argv[(path_index + 2)..]
      @commands << [ path, args ]
      output, exitstatus = response(path, args)
      output = "x" * (max_bytes + 1) if @oversized && args.first == "status"
      truncated = output.bytesize > max_bytes
      [
        output.byteslice(0, max_bytes).to_s, "",
        Hive::TaskWorkspace::Publication::Status.new(
          success?: exitstatus.zero?, exitstatus: exitstatus
        ),
        { stdout_truncated: truncated, stderr_truncated: false }
      ]
    end

    private

    def response(path, args)
      case args
      when [ "rev-parse", "--git-common-dir" ]
        [ "/git/common\n", 0 ]
      when [ "worktree", "list", "--porcelain" ]
        [ "worktree /worktrees/demo\nHEAD #{@head}\nbranch refs/heads/demo\n", 0 ]
      when [ "rev-parse", "--verify", "HEAD" ]
        [ "#{@head}\n", 0 ]
      when [ "branch", "--show-current" ]
        [ "#{@branch}\n", 0 ]
      when [ "status", "--porcelain=v1", "--untracked-files=no" ]
        [ @dirty ? " M changed.rb\n" : "", 0 ]
      else
        if args.first(2) == [ "merge-base", "--is-ancestor" ]
          [ "", 0 ]
        elsif args.first == "log"
          [ [ @head, @head[0, 8], "Ship safely", "2026-08-12T12:00:00Z" ].join("\0") + "\x1e", 0 ]
        elsif args.first(3) == [ "rev-parse", "--verify", "--quiet" ]
          @tracking == :absent ? [ "", 1 ] : [ tracking_oid, 0 ]
        elsif args.first(3) == [ "rev-list", "--left-right", "--count" ]
          counts = { pushed: "0 0\n", ahead: "0 2\n", behind: "2 0\n", divergent: "1 2\n" }
          [ counts.fetch(@tracking), 0 ]
        else
          raise "unexpected git command at #{path}: #{args.inspect}"
        end
      end
    end

    def tracking_oid
      @tracking == :pushed ? "#{@head}\n" : "#{'e' * 40}\n"
    end
  end

  def test_projects_strict_local_pr_and_cached_remote_identity_without_network
    with_task do |task|
      write_pr(task.folder)
      runner = GitRunner.new
      cache = FakeCache.new(remote_result)
      panel = service(task, runner: runner, cache: cache).call

      assert_equal "current", panel.fetch("state")
      assert_equal "open", panel.fetch("publication_state")
      assert_equal "pushed", panel.dig("local", "push", "state")
      assert_equal "Ship safely", panel.dig("local", "commits", 0, "subject")
      assert panel.dig("refresh", "eligible")
      assert_equal "d" * 40, cache.reads.first.fetch("expected_head")
      forbidden = runner.commands.flatten
      refute_includes forbidden, "fetch"
      refute_includes forbidden, "ls-remote"
      refute_includes panel.to_s, task.folder
      refute_includes panel.to_s, "/worktrees/demo"
    end
  end

  def test_legacy_pointer_and_missing_pr_are_honest_and_not_refreshable
    with_task do |task|
      runner = GitRunner.new(tracking: :absent)
      pointer = strict_pointer.slice("path", "branch")
      cache = FakeCache.new(remote_result)

      panel = service(task, runner: runner, cache: cache, pointer: pointer).call

      assert_equal "partial", panel.fetch("state")
      assert_equal "not_configured", panel.fetch("publication_state")
      assert_equal "missing", panel.dig("pull_request", "state")
      refute panel.dig("refresh", "eligible")
      assert_empty cache.reads
      assert_includes panel.fetch("diagnostics").map { |row| row["reason"] },
                      "legacy_pointer_partial"
    end
  end

  def test_foreign_pr_and_declared_head_mismatch_remain_conflicting
    with_task do |task|
      write_pr(
        task.folder,
        url: "https://github.com/other/repo/pull/42",
        head: "a" * 40
      )
      cache = FakeCache.new(remote_result)

      panel = service(task, runner: GitRunner.new, cache: cache).call

      assert_equal "conflicting", panel.fetch("state")
      assert_equal "identity_conflicting", panel.fetch("publication_state")
      assert_equal %w[head repository], panel.dig("pull_request", "conflicts").sort
      refute panel.dig("refresh", "eligible")
      assert_empty cache.reads
    end
  end

  def test_local_tracking_states_distinguish_unpushed_behind_and_divergent
    with_task do |task|
      write_pr(task.folder)
      {
        ahead: [ "local_unpushed", "unpushed" ],
        behind: [ "local_behind", "behind" ],
        divergent: [ "local_divergent", "divergent" ],
        absent: [ "not_observed", "not_observed" ]
      }.each do |tracking, (publication_state, push_state)|
        panel = service(task, runner: GitRunner.new(tracking: tracking)).call
        assert_equal publication_state, panel.fetch("publication_state")
        assert_equal push_state, panel.dig("local", "push", "state")
      end
    end
  end

  def test_local_output_limit_and_pointer_failure_degrade_only_publication
    with_task do |task|
      write_pr(task.folder)
      limited = service(
        task, runner: GitRunner.new(oversized: true),
        limits: Hive::TaskWorkspace::Limits.new(local_git_bytes: 128)
      ).call

      assert_equal "unavailable", limited.dig("local", "state")
      assert_equal "local_unavailable", limited.fetch("publication_state")
      cap = limited.fetch("diagnostics").find { |row| row.dig("details", "cap") == "local_git_bytes" }
      refute_nil cap

      missing = service(task, runner: ->(*) { flunk "git must not run" }, pointer: nil).call
      assert_equal "unavailable", missing.fetch("state")
      assert_equal "worktree_unavailable", missing.fetch("publication_state")
    end
  end

  def test_pr_document_is_bounded_redacted_and_never_trusted_as_html
    with_task do |task|
      token = "ghp_#{'a' * 36}"
      write_pr(task.folder, body: "# <script>bad</script>\n\n#{token}\n" + ("x" * 200))
      panel = service(
        task, runner: GitRunner.new,
        limits: Hive::TaskWorkspace::Limits.new(github_pr_text_bytes: 300)
      ).call

      refute_includes panel.to_s, token
      assert_includes panel.dig("pull_request", "title"), "<script>"
      assert panel.dig("pull_request", "truncated")
      assert_includes panel.fetch("diagnostics").filter_map { |row| row["cap"] },
                      "github_pr_text_bytes"
    end
  end

  def test_cached_remote_head_and_base_divergence_are_explicit_conflicts
    with_task do |task|
      write_pr(task.folder)
      remote = remote_result
      remote["observation"] = remote.fetch("observation").merge(
        "head_oid" => "e" * 40, "head_matches" => false,
        "base_branch" => "other"
      )

      panel = service(task, runner: GitRunner.new, cache: FakeCache.new(remote)).call

      assert_equal "conflicting", panel.fetch("state")
      assert_equal "remote_head_divergent", panel.fetch("publication_state")
      assert_equal "e" * 40, panel.dig("remote", "observation", "head_oid")
      assert_equal "d" * 40, panel.dig("local", "head_oid")
    end
  end

  def test_deleted_merged_rate_limited_and_missing_remote_states_stay_distinct
    with_task do |task|
      write_pr(task.folder)
      cases = {
        "merged_head_deleted" => remote_result.tap do |value|
          value["observation"] = value.fetch("observation").merge(
            "state" => "MERGED", "head_branch_present" => false
          )
        end,
        "remote_branch_deleted" => remote_result.tap do |value|
          value["observation"] = value.fetch("observation").merge("head_branch_present" => false)
        end,
        "remote_rate_limited" => {
          "state" => "unavailable", "refresh_state" => "failed", "observation" => nil,
          "diagnostics" => [ { "reason" => "rate_limited" } ]
        },
        "remote_pr_missing" => {
          "state" => "unavailable", "refresh_state" => "failed", "observation" => nil,
          "diagnostics" => [ { "reason" => "pull_request_missing" } ]
        }
      }

      cases.each do |expected, remote|
        panel = service(task, runner: GitRunner.new, cache: FakeCache.new(remote)).call
        assert_equal expected, panel.fetch("publication_state")
      end
    end
  end

  def test_default_runner_bounds_both_streams_and_enforces_the_deadline
    task = FakeTask.new(folder: "/task", project_root: "/repo", slug: "demo")
    publication = Hive::TaskWorkspace::Publication.new(
      task: task, expected_root: "/worktrees", pointer_reader: -> { strict_pointer }
    )
    output, error, status, metadata = publication.send(
      :run_command,
      [ RbConfig.ruby, "-e", "STDOUT.write('o' * 64); STDERR.write('e' * 64); exit 3" ],
      timeout_sec: 2, max_bytes: 32
    )

    assert_equal "o" * 24, output
    assert_equal "e" * 8, error
    assert_equal 3, status.exitstatus
    assert metadata.fetch(:stdout_truncated)
    assert metadata.fetch(:stderr_truncated)

    failure = assert_raises(Hive::TaskWorkspace::SourceError) do
      publication.send(
        :run_command,
        [ RbConfig.ruby, "-e", "sleep 30" ], timeout_sec: 0.01, max_bytes: 16
      )
    end
    assert_equal "limit_exhausted", failure.reason
    assert_equal "local_git_deadline_seconds", failure.details.fetch("cap")
  end

  private

  def with_task
    with_tmp_dir do |folder|
      yield FakeTask.new(folder: folder, project_root: "/repo", slug: "demo")
    end
  end

  def service(task, runner:, cache: nil, pointer: strict_pointer,
              limits: Hive::TaskWorkspace::Limits.new)
    reader = pointer.nil? ? -> { raise Hive::WorktreeError, "missing" } : -> { pointer }
    Hive::TaskWorkspace::Publication.new(
      task: task, expected_repository: "github.com/acme/demo",
      expected_root: "/worktrees", pointer_reader: reader,
      runner: runner, cache: cache, limits: limits,
      monotonic_clock: -> { 0.0 }
    )
  end

  def strict_pointer
    {
      "path" => "/worktrees/demo", "branch" => "demo",
      "base_branch" => "main", "base_oid" => "c" * 40,
      "repository" => "github.com/acme/demo"
    }
  end

  def write_pr(folder, url: "https://github.com/acme/demo/pull/42",
               head: "d" * 40, body: "# Publish demo\n\nBody\n")
    File.write(File.join(folder, "pr.md"), <<~MARKDOWN)
      ---
      pr_url: #{url}
      pr_number: 42
      head_oid: #{head}
      ---

      #{body}
    MARKDOWN
  end

  def remote_result
    {
      "state" => "current", "cache_state" => "fresh", "refresh_state" => "idle",
      "observed_at" => "2026-08-12T12:00:00Z", "refreshed_at" => "2026-08-12T12:00:00Z",
      "retry_at" => nil, "diagnostics" => [],
      "observation" => {
        "repository" => "github.com/acme/demo", "number" => 42,
        "url" => "https://github.com/acme/demo/pull/42", "state" => "OPEN",
        "is_draft" => false, "head_oid" => "d" * 40,
        "head_branch_present" => true,
        "checks" => [ { "name" => "test", "status" => "COMPLETED", "conclusion" => "SUCCESS" } ],
        "checks_truncated" => false, "review_decision" => "APPROVED"
      }
    }
  end
end
