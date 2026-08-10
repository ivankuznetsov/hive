require_relative "support"

class BabysitterAcceptanceDryRunTest < Minitest::Test
  include HiveTestHelper
  include BabysitterAcceptanceSupport

  def test_dry_run_agent_side_git_and_gh_mutations_are_stubbed
    with_tmp_dir do |dir|
      project = babysitter_project(dir)
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)
      real_bin = File.join(dir, "real-bin")
      real_log = File.join(dir, "real.log")
      install_recording_binary(real_bin, "git", real_log)
      install_recording_binary(real_bin, "gh", real_log)
      pr = babysitter_pr
      command_results = []
      assert_equal_method = method(:assert_equal)

      with_env("PATH" => [ real_bin, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)) do
        with_non_green_babysitter_context(project, worktree_path, pr) do
          with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **kwargs|
            assert_equal_method.call(worktree_path, kwargs.fetch(:cwd))
            assert_equal_method.call([ worktree_path ], kwargs.fetch(:add_dirs))
            Dir.chdir(kwargs.fetch(:cwd)) do
              command_results << system("git", "push", "origin", "HEAD:feature", "--force-with-lease", out: File::NULL, err: File::NULL)
              command_results << system("gh", "pr", "comment", "42", "--body", "would comment", out: File::NULL, err: File::NULL)
              command_results << system("gh", "--repo=owner/repo", "pr", "close", "42", out: File::NULL, err: File::NULL)
              command_results << system("git", "status", "--short", out: File::NULL, err: File::NULL)
              command_results << system("gh", "pr", "view", "42", out: File::NULL, err: File::NULL)
              File.write(".babysitter-dry-run-plan.md", "would repair PR 42\n")
              { status: :ok }
            end
          }) do
            outcome = Hive::Babysitter::PrFixer.run(
              pr,
              project,
              babysitter_cfg,
              dry_run: true,
              logger: acceptance_logger,
              inflight: Set.new
            )
            assert_equal :dry_run, outcome
          end
        end
      end

      real_calls = File.readlines(real_log, chomp: true)
      escaped = real_calls.grep(/\b(?:push|comment|close)\b/)
      flunk "dry-run mutations escaped the PATH overlay: #{escaped.join(', ')}" if escaped.any?
      assert real_calls.any? { |line| line.include?("status --short") },
             "allowlisted git status must pass through to the recorded real binary"
      assert_includes real_calls, "gh pr view 42",
                      "allowlisted gh pr view must pass through to the recorded real binary"
      assert_equal 5, command_results.size,
                   "all three mutations and two reads must run through the dry-run overlay"
      # The load-bearing proof is interception: each mutating git/gh
      # invocation was diverted to the skip log instead of hitting the
      # real remote. The exit statuses only confirm the shims (which
      # always `exit 0`) returned cleanly, so they're a weak signal on
      # their own — the per-command log lines below are what prove the
      # commands were skipped rather than executed.
      assert command_results.all?,
             "each intercepted git/gh shim must exit 0 (#{command_results.inspect})"
      skipped = File.read(File.join(worktree_path, ".babysitter-dry-run-skipped.log"))
      assert_includes skipped, "git push origin HEAD:feature --force-with-lease",
                      "the force-push must be intercepted, never reaching the real remote"
      assert_includes skipped, "gh pr comment 42 --body would comment",
                      "the PR comment must be intercepted, not posted to GitHub"
      assert_includes skipped, "gh --repo=owner/repo pr close 42",
                      "the PR close must be intercepted, not applied on GitHub"
      assert File.exist?(File.join(worktree_path, ".babysitter-dry-run-plan.md")),
             "the dry-run plan artifact must still be written by the stubbed agent"
      assert babysitter_events(project).any? { |event|
        event["action"] == "dry_run" && event["outcome"] == "dry_run" && event["pr"] == 42
      }
    end
  end

  private

  def install_recording_binary(dir, name, log_path)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, name)
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      File.open(#{log_path.dump}, "a") do |file|
        file.puts(([File.basename($PROGRAM_NAME)] + ARGV).join(" "))
      end
      exit 0
    RUBY
    FileUtils.chmod("+x", path)
  end
end
