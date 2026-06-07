require_relative "support"

class BabysitterAcceptanceDryRunTest < Minitest::Test
  include HiveTestHelper
  include BabysitterAcceptanceSupport

  def test_dry_run_agent_side_git_and_gh_mutations_are_stubbed
    with_tmp_dir do |dir|
      project = babysitter_project(dir)
      worktree_path = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree_path)
      pr = babysitter_pr
      command_results = []
      guard_bin = File.join(dir, "path-guards")
      %w[ git gh ].each { |binary| install_failing_path_guard(guard_bin, binary) }

      with_env("PATH" => [ guard_bin, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)) do
        with_non_green_babysitter_context(project, worktree_path, pr) do
          with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **kwargs|
            Dir.chdir(kwargs.fetch(:cwd)) do
              command_results << system("git", "push", "origin", "HEAD:feature", "--force-with-lease", out: File::NULL, err: File::NULL)
              command_results << system("gh", "pr", "comment", "42", "--body", "would comment", out: File::NULL, err: File::NULL)
              command_results << system("gh", "--repo=owner/repo", "pr", "close", "42", out: File::NULL, err: File::NULL)
              File.write(File.join(worktree_path, ".babysitter-dry-run-plan.md"), "would repair PR 42\n")
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

      assert_equal 3, command_results.size,
                   "all three agent-side mutations must run through the stubbed spawn"
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
      %w[ git gh ].each do |binary|
        refute File.exist?(File.join(guard_bin, "#{binary}.log")),
               "dry-run stubs must skip mutating #{binary} commands before reaching the PATH guard"
      end
      assert File.exist?(File.join(worktree_path, ".babysitter-dry-run-plan.md")),
             "the dry-run plan artifact must still be written by the stubbed agent"
      assert babysitter_events(project).any? { |event|
        event["action"] == "dry_run" && event["outcome"] == "dry_run" && event["pr"] == 42
      }
    end
  end

  private
    def install_failing_path_guard(dir, name)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, name)
      File.write(path, <<~RUBY)
        #!/usr/bin/env ruby
        File.open(#{File.join(dir, "#{name}.log").dump}, "a") do |file|
          file.puts(([#{name.dump}] + ARGV).join(" "))
        end
        exit 97
      RUBY
      FileUtils.chmod("+x", path)
    end
end
