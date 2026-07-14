require "test_helper"
require "json"
require "hive/gh"
require "hive/honeycomb"
require "hive/honeycomb/submission"

class HoneycombSubmissionTest < Minitest::Test
  include HiveTestHelper

  class RecordingRunner
    attr_reader :commands, :commit_snapshot, :last_worktree, :last_branch

    def initialize(cache_path:, permission: "WRITE", auth_exit: 0, origin: nil,
                   fork_exists: false, pr_exit: 0, local_collision: false,
                   remote_collision: false, fetch_exit: 0, repo_json: nil,
                   local_exit: nil, remote_exit: nil, fork_is_fork: true,
                   fork_parent: "example/honeycomb", fork_view_error: nil,
                   worktree_add_exit: 0, worktree_workflows_symlink: nil)
      @cache_path = cache_path
      @permission = permission
      @auth_exit = auth_exit
      @origin = origin || "https://github.com/example/honeycomb.git"
      @fork_exists = fork_exists
      @pr_exit = pr_exit
      @local_collision = local_collision
      @remote_collision = remote_collision
      @fetch_exit = fetch_exit
      @repo_json = repo_json
      @local_exit = local_exit
      @remote_exit = remote_exit
      @fork_is_fork = fork_is_fork
      @fork_parent = fork_parent
      @fork_view_error = fork_view_error
      @worktree_add_exit = worktree_add_exit
      @worktree_workflows_symlink = worktree_workflows_symlink
      @forked = false
      @commands = []
    end

    def call(*cmd, chdir: nil, cfg: nil)
      @commands << { argv: cmd, chdir: chdir, cfg: cfg }
      out = ""
      err = ""
      exitstatus = 0

      if cmd == [ "gh", "auth", "status" ]
        exitstatus = @auth_exit
        err = "not authenticated" unless exitstatus.zero?
      elsif cmd[0, 6] == [ "gh", "repo", "view", "example/honeycomb", "--json", cmd[5] ]
        out = @repo_json || JSON.generate(
          "nameWithOwner" => "example/honeycomb",
          "defaultBranchRef" => { "name" => "main" },
          "viewerPermission" => @permission
        )
      elsif cmd[0, 4] == [ "gh", "repo", "view", "alice/honeycomb" ]
        if @fork_exists || @forked
          out = JSON.generate(
            "nameWithOwner" => "alice/honeycomb",
            "isFork" => @fork_is_fork,
            "parent" => @fork_parent ? { "nameWithOwner" => @fork_parent } : nil
          )
        elsif @fork_view_error
          exitstatus = @fork_view_error.fetch(:exit, 1)
          err = @fork_view_error.fetch(:err)
        else
          exitstatus = 1
          err = "HTTP 404: Not Found (https://api.github.com/repos/alice/honeycomb)"
        end
      elsif cmd == [ "gh", "api", "user", "--jq", ".login" ]
        out = "alice\n"
      elsif cmd[0, 4] == [ "gh", "repo", "clone", "example/honeycomb" ]
        FileUtils.mkdir_p(File.join(cmd[4], ".git"))
      elsif cmd == [ "gh", "repo", "fork", "example/honeycomb", "--clone=false", "--remote=false" ]
        @forked = true
        out = "https://github.com/alice/honeycomb\n"
      elsif cmd[0, 3] == [ "gh", "pr", "create" ]
        if @pr_exit.zero?
          out = "https://github.com/example/honeycomb/pull/42\n"
        else
          exitstatus = @pr_exit
          err = "PR create failed"
        end
      elsif cmd == [ "git", "-C", @cache_path, "remote", "get-url", "origin" ]
        out = "#{@origin}\n"
      elsif cmd == [ "git", "-C", @cache_path, "fetch", "--prune", "origin", "main" ]
        exitstatus = @fetch_exit
        err = "fetch failed" unless exitstatus.zero?
      elsif cmd[0, 7] == [ "git", "-C", @cache_path, "show-ref", "--verify", "--quiet", cmd[6] ]
        exitstatus = @local_exit || (@local_collision ? 0 : 1)
      elsif cmd[0, 4] == [ "git", "ls-remote", "--exit-code", "--heads" ]
        exitstatus = @remote_exit || (@remote_collision ? 0 : 2)
      elsif cmd[0, 8] == [ "git", "-C", @cache_path, "worktree", "add", "-b", cmd[6], cmd[7] ]
        @last_worktree = cmd[7]
        @last_branch = cmd[6]
        if @worktree_add_exit.zero?
          if @worktree_workflows_symlink
            FileUtils.mkdir_p(@last_worktree)
            File.symlink(@worktree_workflows_symlink, File.join(@last_worktree, "workflows"))
          else
            FileUtils.mkdir_p(File.join(@last_worktree, "workflows", "sample"))
            FileUtils.mkdir_p(File.join(@last_worktree, "workflows", "other"))
            File.write(File.join(@last_worktree, "workflows", "sample", "stale.txt"), "stale\n")
            File.write(File.join(@last_worktree, "workflows", "other", "keep.txt"), "keep\n")
          end
        else
          # Simulate `git worktree add -b` creating the branch ref but failing
          # to register the worktree (the leaked-branch scenario).
          exitstatus = @worktree_add_exit
          err = "fatal: could not create work tree dir"
        end
      elsif cmd[0, 10] == [ "git", "-c", "user.name=Hive", "-c", "user.email=hive@localhost",
                            "-c", "commit.gpgsign=false", "-C", cmd[8], "commit" ]
        worktree = cmd[8]
        @commit_snapshot = Dir.glob(File.join(worktree, "workflows", "**", "*"))
                              .select { |path| File.file?(path) }
                              .to_h { |path| [ path.delete_prefix("#{worktree}/"), File.binread(path) ] }
      end

      [ out, err, Hive::Gh::CommandStatus.new(exitstatus: exitstatus) ]
    end
  end

  def test_direct_submission_replaces_only_selected_package_and_opens_pr
    with_submission_fixture do |package, cache_path|
      runner = RecordingRunner.new(cache_path: cache_path, permission: "WRITE")
      result = submit(package, cache_path, runner)

      assert_equal "direct", result.mode
      assert_equal "example/honeycomb", result.repository
      assert_equal "submit-sample-v1.2.3", result.branch
      assert_equal "https://github.com/example/honeycomb/pull/42", result.pr_url
      assert_equal "new workflow\n", runner.commit_snapshot.fetch("workflows/sample/workflow.yml")
      refute runner.commit_snapshot.key?("workflows/sample/stale.txt")
      assert_equal "keep\n", runner.commit_snapshot.fetch("workflows/other/keep.txt")
      assert_command runner, [ "git", "-C", runner.last_worktree, "push", "-u", "origin", result.branch ]
      assert_command_includes runner, [ "--head", result.branch ]
      refute File.exist?(runner.last_worktree), "disposable worktree must be cleaned"
    end
  end

  def test_maintain_and_admin_permissions_also_route_direct
    %w[MAINTAIN ADMIN].each do |permission|
      with_submission_fixture do |package, cache_path|
        runner = RecordingRunner.new(cache_path: cache_path, permission: permission)
        result = submit(package, cache_path, runner)

        assert_equal "direct", result.mode, permission
        refute_command runner, [ "gh", "repo", "fork", "example/honeycomb", "--clone=false", "--remote=false" ]
      end
    end
  end

  def test_ssh_scp_and_git_suffix_cache_origins_are_accepted
    [
      "ssh://git@github.com/example/honeycomb",
      "ssh://git@github.com/example/honeycomb.git",
      "git@github.com:example/honeycomb",
      "git@github.com:example/honeycomb.git",
      "https://github.com/example/honeycomb.git"
    ].each do |origin|
      with_submission_fixture(cache_exists: true) do |package, cache_path|
        runner = RecordingRunner.new(cache_path: cache_path, origin: origin)
        result = submit(package, cache_path, runner)

        assert_equal "direct", result.mode, origin
      end
    end
  end

  def test_read_permission_creates_or_reuses_fork_and_uses_cross_repo_head
    with_submission_fixture do |package, cache_path|
      runner = RecordingRunner.new(cache_path: cache_path, permission: "READ")
      result = submit(package, cache_path, runner)

      assert_equal "fork", result.mode
      assert_equal "alice/honeycomb", result.push_repository
      assert_command runner, [ "gh", "repo", "fork", "example/honeycomb", "--clone=false", "--remote=false" ]
      assert_command runner, [
        "git", "-C", runner.last_worktree, "push", "-u",
        "https://github.com/alice/honeycomb.git", result.branch
      ]
      assert_command_includes runner, [ "--head", "alice:#{result.branch}" ]
      # The fetch/worktree base must be the upstream default branch, never the fork.
      assert_command_includes runner, [ runner.last_worktree, "origin/main" ]
      assert_command runner, [ "git", "-C", cache_path, "fetch", "--prune", "origin", "main" ]
    end

    with_submission_fixture do |package, cache_path|
      runner = RecordingRunner.new(cache_path: cache_path, permission: "TRIAGE", fork_exists: true)
      submit(package, cache_path, runner)
      refute_command runner, [ "gh", "repo", "fork", "example/honeycomb", "--clone=false", "--remote=false" ]
    end
  end

  def test_cache_miss_clones_once_and_cache_hit_fetches_after_origin_verification
    with_submission_fixture do |package, cache_path|
      runner = RecordingRunner.new(cache_path: cache_path)
      submit(package, cache_path, runner)
      submit(package, cache_path, runner)

      clones = runner.commands.count { |row| row[:argv][0, 3] == [ "gh", "repo", "clone" ] }
      fetches = runner.commands.count { |row| row[:argv][0, 5] == [ "git", "-C", cache_path, "fetch", "--prune" ] }
      assert_equal 1, clones
      assert_equal 2, fetches
    end
  end

  def test_auth_origin_fetch_and_branch_collisions_fail_closed
    scenarios = [
      [ { auth_exit: 1 }, /not authenticated/ ],
      [ { origin: "https://github.com/wrong/repository.git" }, /cached honeycomb origin/ ],
      [ { fetch_exit: 1 }, /git fetch failed/ ],
      [ { local_collision: true }, /local branch.*already exists/ ],
      [ { remote_collision: true }, /remote branch.*already exists/ ]
    ]
    scenarios.each do |options, message|
      with_submission_fixture(cache_exists: options.key?(:origin)) do |package, cache_path|
        runner = RecordingRunner.new(cache_path: cache_path, **options)
        error = assert_raises(Hive::Honeycomb::Submission::Error) do
          submit(package, cache_path, runner)
        end
        assert_match message, error.message
      end
    end
  end

  def test_invalid_repository_metadata_json_and_cache_shape_fail_closed
    scenarios = [
      [ { repo_json: JSON.generate("nameWithOwner" => "wrong/repository") }, /invalid repository metadata/ ],
      [ { repo_json: "{" }, /invalid JSON/ ]
    ]
    scenarios.each do |options, message|
      with_submission_fixture do |package, cache_path|
        runner = RecordingRunner.new(cache_path: cache_path, **options)
        error = assert_raises(Hive::Honeycomb::Submission::Error) do
          submit(package, cache_path, runner)
        end
        assert_match message, error.message
      end
    end

    with_submission_fixture do |package, cache_path|
      FileUtils.mkdir_p(cache_path)
      runner = RecordingRunner.new(cache_path: cache_path)
      error = assert_raises(Hive::Honeycomb::Submission::Error) do
        submit(package, cache_path, runner)
      end
      assert_match(/exists but is not a git checkout/, error.message)
    end
  end

  def test_unexpected_local_and_remote_branch_probe_failures_surface_context
    [
      [ { local_exit: 3 }, /inspect local honeycomb branches/ ],
      [ { remote_exit: 3 }, /inspect remote honeycomb branches/ ]
    ].each do |options, message|
      with_submission_fixture do |package, cache_path|
        runner = RecordingRunner.new(cache_path: cache_path, **options)
        error = assert_raises(Hive::Honeycomb::Submission::Error) do
          submit(package, cache_path, runner)
        end
        assert_match message, error.message
      end
    end
  end

  def test_materialization_failure_is_wrapped_and_cleans_unpushed_worktree
    with_submission_fixture do |package, cache_path|
      FileUtils.rm_rf(package.package_root)
      runner = RecordingRunner.new(cache_path: cache_path)

      error = assert_raises(Hive::Honeycomb::Submission::Error) do
        submit(package, cache_path, runner)
      end

      assert_match(/failed to materialize honeycomb package/, error.message)
      refute File.exist?(runner.last_worktree)
      refute_kind_of Hive::Honeycomb::Submission::PartialError, error
    end
  end

  def test_cleanup_retries_local_removal_when_fileutils_raises
    with_submission_fixture do |package, cache_path|
      runner = RecordingRunner.new(cache_path: cache_path)
      original = FileUtils.method(:rm_rf)
      raised = false
      replacement = lambda do |path, *args|
        if path == runner.last_worktree && !raised
          raised = true
          raise IOError, "cleanup race"
        end
        original.call(path, *args)
      end

      result = with_replaced_singleton_method(FileUtils, :rm_rf, replacement) do
        submit(package, cache_path, runner)
      end

      assert_equal "direct", result.mode
      assert raised
      refute File.exist?(runner.last_worktree)
    end
  end

  def test_runner_gh_error_is_normalized_to_submission_error
    with_submission_fixture do |package, cache_path|
      runner = ->(*, **) { raise Hive::GhError, "transport failed" }

      error = assert_raises(Hive::Honeycomb::Submission::Error) do
        Hive::Honeycomb::Submission.submit(
          package: package,
          repository: "example/honeycomb",
          cache_path: cache_path,
          runner: runner,
          locker: ->(_path, &block) { block.call }
        )
      end

      assert_equal "transport failed", error.message
    end
  end

  def test_pr_failure_reports_pushed_recovery_branch_and_cleans_worktree
    with_submission_fixture do |package, cache_path|
      runner = RecordingRunner.new(cache_path: cache_path, pr_exit: 1)
      error = assert_raises(Hive::Honeycomb::Submission::PartialError) do
        submit(package, cache_path, runner)
      end

      assert_equal "example/honeycomb", error.repository
      assert_equal "submit-sample-v1.2.3", error.branch
      assert_includes error.message, "pushed branch"
      refute File.exist?(runner.last_worktree)
    end
  end

  def test_transient_fork_status_failure_fails_closed_without_forking
    with_submission_fixture do |package, cache_path|
      runner = RecordingRunner.new(
        cache_path: cache_path, permission: "READ",
        fork_view_error: { exit: 1, err: "HTTP 500: Internal Server Error" }
      )
      error = assert_raises(Hive::Honeycomb::Submission::Error) do
        submit(package, cache_path, runner)
      end

      assert_match(/could not determine fork status/, error.message)
      refute_command runner, [ "gh", "repo", "fork", "example/honeycomb", "--clone=false", "--remote=false" ]
    end
  end

  def test_existing_namesake_that_is_not_a_fork_of_upstream_is_refused
    with_submission_fixture do |package, cache_path|
      runner = RecordingRunner.new(
        cache_path: cache_path, permission: "READ",
        fork_exists: true, fork_is_fork: false, fork_parent: nil
      )
      error = assert_raises(Hive::Honeycomb::Submission::Error) do
        submit(package, cache_path, runner)
      end

      assert_match(/is not a fork of example\/honeycomb/, error.message)
      refute_command runner, [ "git", "-C", runner.last_worktree.to_s, "push", "-u",
                               "https://github.com/alice/honeycomb.git", "submit-sample-v1.2.3" ]
    end

    with_submission_fixture do |package, cache_path|
      runner = RecordingRunner.new(
        cache_path: cache_path, permission: "READ",
        fork_exists: true, fork_parent: "someone-else/honeycomb"
      )
      error = assert_raises(Hive::Honeycomb::Submission::Error) do
        submit(package, cache_path, runner)
      end
      assert_match(/is not a fork of example\/honeycomb/, error.message)
    end
  end

  def test_fork_creation_disables_remote_reconfiguration_and_waits_for_readiness
    with_submission_fixture do |package, cache_path|
      runner = RecordingRunner.new(cache_path: cache_path, permission: "READ")
      result = submit(package, cache_path, runner)

      assert_equal "fork", result.mode
      fork_call = runner.commands.find { |row| row[:argv][0, 3] == [ "gh", "repo", "fork" ] }
      assert_equal [ "gh", "repo", "fork", "example/honeycomb", "--clone=false", "--remote=false" ],
                   fork_call.fetch(:argv)
      # Runs from a neutral directory (never inside a git checkout) so no local
      # remotes are reconfigured.
      assert_equal File.dirname(cache_path), fork_call.fetch(:chdir)
      # Readiness poll happens after the fork is created, before the push.
      assert_command runner, [ "gh", "repo", "view", "alice/honeycomb", "--json", "nameWithOwner" ]
    end
  end

  def test_cache_miss_clone_pins_blobless_filter_argv
    with_submission_fixture do |package, cache_path|
      runner = RecordingRunner.new(cache_path: cache_path)
      submit(package, cache_path, runner)

      assert_command runner, [
        "gh", "repo", "clone", "example/honeycomb", cache_path, "--", "--filter=blob:none"
      ]
    end
  end

  def test_no_push_uses_force_on_any_route
    [ "WRITE", "READ" ].each do |permission|
      with_submission_fixture do |package, cache_path|
        runner = RecordingRunner.new(cache_path: cache_path, permission: permission)
        submit(package, cache_path, runner)

        pushes = runner.commands.map { |row| row.fetch(:argv) }
                       .select { |argv| argv[0, 2] == [ "git", "-C" ] && argv.include?("push") }
        refute_empty pushes, permission
        pushes.each do |argv|
          refute_includes argv, "--force", "#{permission}: push must not force"
          refute_includes argv, "--force-with-lease", "#{permission}: push must not force-with-lease"
          refute_includes argv, "-f", permission
        end
      end
    end
  end

  def test_leaked_branch_is_deleted_when_worktree_add_fails
    with_submission_fixture do |package, cache_path|
      runner = RecordingRunner.new(cache_path: cache_path, worktree_add_exit: 1)
      assert_raises(Hive::Honeycomb::Submission::Error) do
        submit(package, cache_path, runner)
      end

      # `git worktree add -b` failed (branch ref may have leaked), so cleanup
      # must delete the branch even though the worktree was never registered.
      assert_command runner, [ "git", "-C", cache_path, "branch", "-D", "submit-sample-v1.2.3" ]
    end
  end

  def test_symlinked_workflows_in_registry_worktree_is_refused
    with_submission_fixture do |package, cache_path|
      outside = Dir.mktmpdir("outside-")
      begin
        runner = RecordingRunner.new(cache_path: cache_path, worktree_workflows_symlink: outside)
        error = assert_raises(Hive::Honeycomb::Submission::Error) do
          submit(package, cache_path, runner)
        end

        assert_match(/symlink/, error.message)
        assert_empty Dir.children(outside), "must not write the package through a workflows symlink"
      ensure
        FileUtils.remove_entry(outside)
      end
    end
  end

  def test_review_required_findings_are_detailed_in_the_pr_body
    with_submission_fixture do |package, cache_path|
      package = package.with_manifest(package.manifest.merge(
        "review_required" => [
          {
            "rule" => "shell_download_to_interpreter",
            "file" => "work.md",
            "line" => 12,
            "contexts" => [ "stage:work" ],
            "justification" => "stage:work: digest-pinned internal installer"
          }
        ]
      ))
      runner = RecordingRunner.new(cache_path: cache_path)
      submit(package, cache_path, runner)

      pr_call = runner.commands.find { |row| row[:argv][0, 3] == [ "gh", "pr", "create" ] }
      body = pr_call.fetch(:argv)[pr_call.fetch(:argv).index("--body") + 1]
      assert_includes body, "## Review-required findings"
      assert_includes body, "`shell_download_to_interpreter` at work.md:12"
      assert_includes body, "contexts: stage:work"
      assert_includes body, "digest-pinned internal installer"
    end
  end

  def test_lock_collision_is_retryable_and_does_not_authenticate
    with_submission_fixture do |package, cache_path|
      runner = RecordingRunner.new(cache_path: cache_path)
      locker = lambda do |_path, &_block|
        raise Hive::ConcurrentRunError.new("cache busy", lock_path: "/tmp/cache.lock")
      end

      assert_raises(Hive::ConcurrentRunError) do
        Hive::Honeycomb::Submission.submit(
          package: package,
          repository: "example/honeycomb",
          cache_path: cache_path,
          runner: runner.method(:call),
          locker: locker
        )
      end
      assert_empty runner.commands
    end
  end

  private

    def with_submission_fixture(cache_exists: false)
      with_tmp_dir do |dir|
        package_root = File.join(dir, "package")
        FileUtils.mkdir_p(package_root)
        File.write(File.join(package_root, "workflow.yml"), "new workflow\n")
        cache_path = File.join(dir, "cache", "honeycomb")
        FileUtils.mkdir_p(File.join(cache_path, ".git")) if cache_exists
        package = Hive::Honeycomb::Package.new(
          staging_root: dir,
          package_root: package_root,
          owns_staging_root: false,
          id: "sample",
          version: "1.2.3",
          metadata: {
            "version" => "1.2.3", "author" => "Author", "description" => "Description",
            "minimum_hive_version" => "0.3.7"
          },
          owners: {},
          dependencies: [],
          permission_summary: { "contexts" => [], "aggregate" => {} },
          manifest: {
            "aggregate_sha256" => "abc123",
            "rule_sets" => { "secrets" => 1, "deny" => 1 },
            "review_required" => []
          }
        )
        yield(package, cache_path)
      end
    end

    def submit(package, cache_path, runner)
      Hive::Honeycomb::Submission.submit(
        package: package,
        repository: "example/honeycomb",
        cache_path: cache_path,
        runner: runner.method(:call),
        locker: ->(_path, &block) { block.call },
        sleeper: ->(_seconds) {}
      )
    end

    def assert_command(runner, expected)
      assert(runner.commands.any? { |row| row.fetch(:argv) == expected },
             "expected command #{expected.inspect}; got #{runner.commands.map { |row| row[:argv] }.inspect}")
    end

    def refute_command(runner, expected)
      refute(runner.commands.any? { |row| row.fetch(:argv) == expected },
             "unexpected command #{expected.inspect}")
    end

    def assert_command_includes(runner, subsequence)
      assert(runner.commands.any? do |row|
        argv = row.fetch(:argv)
        argv.each_cons(subsequence.length).any? { |slice| slice == subsequence }
      end, "expected argv subsequence #{subsequence.inspect}")
    end
end
