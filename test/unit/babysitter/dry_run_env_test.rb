require "test_helper"
require "open3"
require "hive/babysitter/dry_run_env"

class BabysitterDryRunEnvTest < Minitest::Test
  include HiveTestHelper

  def test_with_env_intercepts_mutating_git_and_gh_calls
    with_tmp_dir do |dir|
      Hive::Babysitter::DryRunEnv.with_env(dir) do
        git_out, git_err, git_status = Open3.capture3("git", "push", "origin", "feature", "--force-with-lease")
        gh_out, gh_err, gh_status = Open3.capture3("gh", "pr", "comment", "42", "--body", "hi")

        assert git_status.success?, git_err
        assert gh_status.success?, gh_err
        assert_equal "", git_out
        assert_equal "", gh_out
      end

      log = File.read(File.join(dir, ".babysitter-dry-run-skipped.log"))
      assert_includes log, "git push origin feature --force-with-lease skipped"
      assert_includes log, "gh pr comment 42 --body hi skipped"
    end
  end

  def test_stubs_skip_unknown_and_mutating_commands_but_allow_read_only_commands
    with_tmp_dir do |dir|
      real_gh = recording_binary(dir, "real-gh")
      real_git = recording_binary(dir, "real-git")
      log_path = File.join(dir, "skipped.log")
      env = {
        "HIVE_BABYSITTER_REAL_GH" => real_gh,
        "HIVE_BABYSITTER_REAL_GIT" => real_git,
        "HIVE_BABYSITTER_DRY_RUN_LOG" => log_path
      }

      assert_stubbed env, "gh", "-R", "owner/repo", "pr", "ready", "42"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "close", "42"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "reopen", "42"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "merge", "42"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "lock", "42"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "unlock", "42"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "edit", "42", "--add-label", "ready"
      assert_stubbed env, "gh", "--repo=owner/repo", "pr", "edit", "42", "--add-assignee", "@me"
      assert_stubbed env, "gh", "api", "-X", "POST", "repos/owner/repo/dispatches"
      assert_stubbed env, "gh", "api", "repos/owner/repo/issues/123/comments", "-f", "body=hi"
      assert_stubbed env, "gh", "api", "repos/owner/repo/issues/123/comments", "-F", "body=@comment.md"
      assert_stubbed env, "gh", "api", "repos/owner/repo/issues/123/comments", "--raw-field", "body=hi"
      assert_stubbed env, "gh", "api", "repos/owner/repo/issues/123/comments", "--field", "body=hi"
      assert_stubbed env, "gh", "api", "repos/owner/repo/issues/123/comments", "--input", "payload.json"
      assert_stubbed env, "gh", "pr", "view", "42", "--web"
      assert_stubbed env, "gh", "pr", "checks", "42", "-w"
      assert_stubbed env, "gh", "repo", "view", "owner/repo", "--web"
      assert_stubbed env, "gh", "run", "view", "123", "-w"
      assert_stubbed env, "gh", "workflow", "view", "release.yml", "--web"
      assert_stubbed env, "gh", "workflow", "run", "release.yml"
      assert_stubbed env, "gh", "totally-new-write-command", "arg"
      assert_passes env, "gh", "--repo=owner/repo", "pr", "view", "42"
      assert_passes env, "gh", "run", "list", "-w", "release.yml"
      assert_passes env, "gh", "api", "repos/owner/repo"
      assert_passes env, "gh", "api", "--method", "GET", "repos/owner/repo/issues", "-f", "state=open"

      assert_stubbed env, "git", "-C", dir, "push", "origin", "HEAD:feature"
      assert_stubbed env, "git", "commit", "-m", "dry run must not commit"
      assert_stubbed env, "git", "merge", "feature"
      assert_stubbed env, "git", "remote", "set-url", "origin", "git@example.com:owner/repo.git"
      assert_stubbed env, "git", "remote", "add", "upstream", "git@example.com:owner/upstream.git"
      assert_stubbed env, "git", "remote", "remove", "upstream"
      assert_stubbed env, "git", "diff", "--output=patch.diff"
      assert_stubbed env, "git", "diff", "--output", "patch.diff"
      # Exec/write vectors that pass the subcommand allowlist but make real git
      # run an arbitrary command or write a file must be screened across argv.
      assert_stubbed env, "git", "-c", "diff.external=touch pwned", "diff"
      assert_stubbed env, "git", "-c", "core.pager=touch pwned", "show"
      assert_stubbed env, "git", "--config-env=diff.external=PWN", "diff"
      # Two-token `--config-env KEY=VAL` form (not just the glued `=` spelling).
      assert_stubbed env, "git", "--config-env", "diff.external=PWN", "diff"
      # `--exec-path=<dir>` redirects git's helper-binary lookup (exec class).
      assert_stubbed env, "git", "--exec-path=/tmp/evil", "diff"
      assert_stubbed env, "git", "grep", "-Otouch pwned", "needle"
      # Bundled short option (`-nO…`) must not slip past the `-O` pager screen.
      assert_stubbed env, "git", "grep", "-nOtouch pwned", "needle"
      assert_stubbed env, "git", "grep", "--open-files-in-pager=touch pwned", "needle"
      # Bare `--open-files-in-pager` (no glued value) is equally a pager exec.
      assert_stubbed env, "git", "grep", "--open-files-in-pager", "needle"
      # Trailing bare two-token global option must not underflow / crash.
      assert_stubbed env, "git", "-c"
      assert_stubbed env, "git", "-C"
      assert_stubbed env, "git", "--config-env"
      assert_stubbed env, "git", "--output=patch.diff", "diff"
      assert_stubbed env, "git", "log", "--output=log.txt"
      assert_stubbed env, "git", "show", "--output=show.txt"
      assert_stubbed env, "git", "unknown-write-command"
      assert_passes env, "git", "-C", dir, "status", "--short"
      assert_passes env, "git", "diff", "--name-only"
      # Read-only diff orderfile (`-O<file>`) and formatting flags
      # (`--output-indicator-*`) must pass — the pager screen is grep-scoped and
      # `--output` is matched exactly.
      assert_passes env, "git", "diff", "-Oorderfile", "--name-only"
      assert_passes env, "git", "diff", "--output-indicator-new=>", "--name-only"
      assert_passes env, "git", "grep", "needle"
      # `git grep -c` (= --count) is read-only; `-c` is dangerous only as a
      # global option, so it must pass here.
      assert_passes env, "git", "grep", "-c", "needle"
      assert_passes env, "git", "config", "--get", "remote.origin.url"
      assert_passes env, "git", "remote"
      assert_passes env, "git", "remote", "-v"
      assert_passes env, "git", "remote", "show", "-n", "origin"
      assert_passes env, "git", "remote", "get-url", "--push", "origin"

      skipped = File.read(log_path)
      assert_includes skipped, "gh -R owner/repo pr ready 42 skipped"
      assert_includes skipped, "gh --repo=owner/repo pr close 42 skipped"
      assert_includes skipped, "gh --repo=owner/repo pr reopen 42 skipped"
      assert_includes skipped, "gh --repo=owner/repo pr merge 42 skipped"
      assert_includes skipped, "gh --repo=owner/repo pr lock 42 skipped"
      assert_includes skipped, "gh --repo=owner/repo pr unlock 42 skipped"
      assert_includes skipped, "gh --repo=owner/repo pr edit 42 --add-label ready skipped"
      assert_includes skipped, "gh --repo=owner/repo pr edit 42 --add-assignee @me skipped"
      assert_includes skipped, "gh api -X POST repos/owner/repo/dispatches skipped"
      assert_includes skipped, "gh api repos/owner/repo/issues/123/comments -f body=hi skipped"
      assert_includes skipped, "gh api repos/owner/repo/issues/123/comments -F body=@comment.md skipped"
      assert_includes skipped, "gh api repos/owner/repo/issues/123/comments --raw-field body=hi skipped"
      assert_includes skipped, "gh api repos/owner/repo/issues/123/comments --field body=hi skipped"
      assert_includes skipped, "gh api repos/owner/repo/issues/123/comments --input payload.json skipped"
      assert_includes skipped, "gh pr view 42 --web skipped"
      assert_includes skipped, "gh pr checks 42 -w skipped"
      assert_includes skipped, "gh repo view owner/repo --web skipped"
      assert_includes skipped, "gh run view 123 -w skipped"
      assert_includes skipped, "gh workflow view release.yml --web skipped"
      assert_includes skipped, "gh workflow run release.yml skipped"
      assert_includes skipped, "git -C #{dir} push origin HEAD:feature skipped"
      assert_includes skipped, "git commit -m dry run must not commit skipped"
      assert_includes skipped, "git merge feature skipped"
      assert_includes skipped, "git remote set-url origin git@example.com:owner/repo.git skipped"
      assert_includes skipped, "git remote add upstream git@example.com:owner/upstream.git skipped"
      assert_includes skipped, "git remote remove upstream skipped"
      assert_includes skipped, "git diff --output=patch.diff skipped"
      assert_includes skipped, "git diff --output patch.diff skipped"
      assert_includes skipped, "git -c diff.external=touch pwned diff skipped"
      assert_includes skipped, "git -c core.pager=touch pwned show skipped"
      assert_includes skipped, "git --config-env=diff.external=PWN diff skipped"
      assert_includes skipped, "git grep -Otouch pwned needle skipped"
      assert_includes skipped, "git grep --open-files-in-pager=touch pwned needle skipped"
      assert_includes skipped, "git --output=patch.diff diff skipped"
      assert_includes skipped, "git log --output=log.txt skipped"
      assert_includes skipped, "git show --output=show.txt skipped"

      real_invocations = File.read(File.join(dir, "real.log"))
      assert_includes real_invocations, "real-gh --repo=owner/repo pr view 42"
      assert_includes real_invocations, "real-gh run list -w release.yml"
      assert_includes real_invocations, "real-gh api repos/owner/repo"
      assert_includes real_invocations, "real-gh api --method GET repos/owner/repo/issues -f state=open"
      assert_includes real_invocations, "real-git -C #{dir} status --short"
      assert_includes real_invocations, "real-git diff --name-only"
      assert_includes real_invocations, "real-git grep needle"
      assert_includes real_invocations, "real-git config --get remote.origin.url"
      assert_includes real_invocations, "real-git remote"
      assert_includes real_invocations, "real-git remote -v"
      assert_includes real_invocations, "real-git remote show -n origin"
      assert_includes real_invocations, "real-git remote get-url --push origin"
    end
  end

  private

  def assert_stubbed(env, binary, *args)
    _out, err, status = Open3.capture3(env, stub_path(binary), *args)
    assert status.success?, err
    assert_includes err, "[dry-run] #{binary} #{args.join(' ')} skipped"
  end

  def assert_passes(env, binary, *args)
    _out, err, status = Open3.capture3(env, stub_path(binary), *args)
    assert status.success?, err
  end

  def recording_binary(dir, name)
    path = File.join(dir, name)
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      File.open(#{File.join(dir, "real.log").dump}, "a") do |file|
        file.puts(([File.basename($PROGRAM_NAME)] + ARGV).join(" "))
      end
    RUBY
    FileUtils.chmod("+x", path)
    path
  end

  def stub_path(binary)
    File.expand_path("../../../bin/hive-babysitter-stub-#{binary}", __dir__)
  end
end
