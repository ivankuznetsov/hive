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
      fake_bin = File.join(dir, "fake-pre-overlay-bin")
      fake_invocations = File.join(dir, "fake-pre-overlay-invocations.log")
      install_fake_pre_overlay_binary(fake_bin, "git", fake_invocations)
      install_fake_pre_overlay_binary(fake_bin, "gh", fake_invocations)

      with_fake_pre_overlay_path(fake_bin) do
        with_non_green_babysitter_context(project, worktree_path, pr) do
          with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, lambda { |_task, **_kwargs|
            command_results << system("git", "push", "origin", "HEAD:feature", "--force-with-lease", out: File::NULL, err: File::NULL)
            command_results << system("gh", "pr", "comment", "42", "--body", "would comment", out: File::NULL, err: File::NULL)
            command_results << system("gh", "--repo=owner/repo", "pr", "close", "42", out: File::NULL, err: File::NULL)
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
      end

      assert_equal [ true, true, true ], command_results
      refute File.exist?(fake_invocations), "dry-run mutating commands reached the pre-overlay fake git/gh binaries"
      skipped = File.read(File.join(worktree_path, ".babysitter-dry-run-skipped.log"))
      assert_includes skipped, "git push origin HEAD:feature --force-with-lease"
      assert_includes skipped, "gh pr comment 42 --body would comment"
      assert_includes skipped, "gh --repo=owner/repo pr close 42"
      assert File.exist?(File.join(worktree_path, ".babysitter-dry-run-plan.md"))
      assert babysitter_events(project).any? { |event|
        event["action"] == "dry_run" && event["outcome"] == "dry_run" && event["pr"] == 42
      }
    end
  end

  private

  def with_fake_pre_overlay_path(fake_bin)
    old_path = ENV["PATH"]
    ENV["PATH"] = [ fake_bin, old_path ].compact.join(File::PATH_SEPARATOR)
    yield
  ensure
    old_path.nil? ? ENV.delete("PATH") : ENV["PATH"] = old_path
  end

  def install_fake_pre_overlay_binary(fake_bin, name, invocations_path)
    FileUtils.mkdir_p(fake_bin)
    path = File.join(fake_bin, name)
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      File.open(#{invocations_path.dump}, "a") do |file|
        file.puts(([File.basename($PROGRAM_NAME)] + ARGV).join(" "))
      end
      exit 88
    RUBY
    FileUtils.chmod("+x", path)
  end
end
