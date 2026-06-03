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

      with_non_green_babysitter_context(project, worktree_path, pr) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **_kwargs|
          command_results << system("git", "push", "origin", "HEAD:feature", "--force-with-lease", out: File::NULL, err: File::NULL)
          command_results << system("gh", "pr", "comment", "42", "--body", "would comment", out: File::NULL, err: File::NULL)
          File.write(File.join(worktree_path, ".babysitter-dry-run-plan.md"), "would repair PR 42\n")
          { status: :ok }
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

      assert_equal [ true, true ], command_results
      skipped = File.read(File.join(worktree_path, ".babysitter-dry-run-skipped.log"))
      assert_includes skipped, "git push origin HEAD:feature --force-with-lease"
      assert_includes skipped, "gh pr comment 42 --body would comment"
      assert File.exist?(File.join(worktree_path, ".babysitter-dry-run-plan.md"))
      assert babysitter_events(project).any? { |event|
        event["action"] == "dry_run" && event["outcome"] == "dry_run" && event["pr"] == 42
      }
    end
  end
end
