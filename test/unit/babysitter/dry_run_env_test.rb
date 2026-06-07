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
      @real_log = File.join(dir, "real.log")
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
      assert_stubbed env, "gh", "auth", "status", "--show-token"
      assert_stubbed env, "gh", "auth", "status", "-t"
      assert_stubbed env, "gh", "auth", "status", "--json", "hosts", "--show-token"
      assert_stubbed env, "gh", "workflow", "run", "release.yml"
      assert_stubbed env, "gh", "totally-new-write-command", "arg"
      assert_passes env, "gh", "auth", "status"
      assert_passes env, "gh", "auth", "status", "--active", "--hostname", "github.example.com"
      assert_passes env, "gh", "auth", "status", "--json", "hosts", "--jq", ".hosts"
      assert_passes env, "gh", "--repo=owner/repo", "pr", "view", "42"
      assert_passes env, "gh", "api", "repos/owner/repo"
      assert_passes env, "gh", "api", "--method", "GET", "repos/owner/repo/issues", "-f", "state=open"

      assert_stubbed env, "git", "-C", dir, "push", "origin", "HEAD:feature"
      assert_stubbed env, "git", "commit", "-m", "dry run must not commit"
      assert_stubbed env, "git", "merge", "feature"
      assert_stubbed env, "git", "config", "user.name", "newvalue", "--get"
      assert_stubbed env, "git", "config", "user.email", "newvalue", "--get-all"
      assert_stubbed env, "git", "config", "commit.gpgsign", "false", "--list"
      assert_stubbed env, "git", "remote", "set-url", "origin", "git@example.com:owner/repo.git"
      assert_stubbed env, "git", "remote", "add", "upstream", "git@example.com:owner/upstream.git"
      assert_stubbed env, "git", "remote", "remove", "upstream"
      # Mutating `remote` subcommands beyond set-url/add/remove must skip too.
      assert_stubbed env, "git", "remote", "rename", "origin", "upstream"
      assert_stubbed env, "git", "remote", "prune", "origin"
      assert_stubbed env, "git", "remote", "update"
      assert_stubbed env, "git", "remote", "set-head", "origin", "main"
      assert_stubbed env, "git", "remote", "set-branches", "origin", "main"
      assert_stubbed env, "git", "-c", "diff.external=touch /tmp/hive-dryrun-pwn", "diff"
      assert_stubbed env, "git", "-c", "core.fsmonitor=touch /tmp/hive-fsmonitor-pwn", "status"
      assert_stubbed env, "git", "--config-env=core.pager=HIVE_TEST_PAGER", "log", "--oneline"
      assert_stubbed env, "git", "--paginate", "log", "--oneline"
      assert_stubbed env, "git", "grep", "--open-files-in-pager=touch /tmp/hive-pager-pwn", "needle"
      # On `git grep`, `-O` is the short form of `--open-files-in-pager`; both glued and
      # separate forms run an attacker-controlled pager command and must be rejected. (On
      # diff/log/show `-O` is the read-only `--output-ordering` — see the passthrough cases.)
      assert_stubbed env, "git", "grep", "-Otouch /tmp/hive-pager-short-pwn", "needle"
      assert_stubbed env, "git", "grep", "-O", "touch /tmp/hive-pager-sep-pwn", "needle"
      # Same-class arbitrary-exec config keys are rejected by the allowlist (reject all
      # global config overrides), not by a denylist that has to enumerate each one.
      assert_stubbed env, "git", "-c", "diff.x.textconv=touch /tmp/hive-textconv-pwn", "diff"
      assert_stubbed env, "git", "-c", "diff.x.command=touch /tmp/hive-diffcmd-pwn", "diff"
      assert_stubbed env, "git", "-c", "filter.x.clean=touch /tmp/hive-filter-pwn", "diff"
      assert_stubbed env, "git", "-c", "gpg.ssh.program=touch /tmp/hive-gpg-pwn", "log", "--show-signature"
      assert_stubbed env, "git", "-cdiff.x.textconv=touch /tmp/hive-glued-pwn", "diff"
      assert_stubbed env, "git", "--config-env", "core.pager=HIVE_TEST_PAGER", "log"
      # Arbitrary file-write options defeat the no-mutation boundary on allowed reads.
      assert_stubbed env, "git", "diff", "--output=/tmp/hive-output-pwn"
      assert_stubbed env, "git", "log", "-p", "--output", "/tmp/hive-output-sep-pwn"
      assert_stubbed env, "git", "diff", "-o", "/tmp/hive-output-short-pwn"
      assert_stubbed env, "git", "diff", "-o/tmp/hive-output-glued-pwn"
      assert_stubbed env, "git", "diff", "--ext-diff"
      # The read/write boundary for ls-files: `-o` / `--others` is a read (allowed below), but
      # the file-writing `--output` long form must still skip — narrowing the guard must not
      # re-allow the write form.
      assert_stubbed env, "git", "ls-files", "--output", "/tmp/hive-lsfiles-output-pwn"
      # The env-var config path bypasses every argv guard above: GIT_EXTERNAL_DIFF /
      # GIT_SSH_COMMAND name a command git execs directly, and GIT_CONFIG_COUNT +
      # GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n inject the same exec-capable keys as `-c`. An
      # otherwise-allowlisted read like `git diff` must skip, fail-closed, when they are set.
      assert_stubbed env.merge("GIT_EXTERNAL_DIFF" => "touch /tmp/hive-extdiff-pwn"), "git", "diff"
      assert_stubbed env.merge("GIT_SSH_COMMAND" => "touch /tmp/hive-ssh-pwn"), "git", "ls-files"
      assert_stubbed env.merge(
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "diff.external",
        "GIT_CONFIG_VALUE_0" => "touch /tmp/hive-envconfig-pwn"
      ), "git", "diff"
      # GIT_CONFIG_PARAMETERS is git's older one-shot config channel; it carries the same
      # exec-capable keys (diff.external, core.fsmonitor, …) as `-c`, so it must skip too.
      assert_stubbed env.merge(
        "GIT_CONFIG_PARAMETERS" => "'diff.external=touch /tmp/hive-cfgparams-pwn'"
      ), "git", "diff"
      # GIT_SSH / GIT_PROXY_COMMAND are the older exec-capable siblings of GIT_SSH_COMMAND —
      # each names a program git execs — and must skip on the network-reaching reads they hit.
      assert_stubbed env.merge("GIT_SSH" => "touch /tmp/hive-gitssh-pwn"), "git", "remote", "show", "origin"
      assert_stubbed env.merge("GIT_PROXY_COMMAND" => "touch /tmp/hive-proxy-pwn"), "git", "status"
      # GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM repoint config at an attacker-written file that
      # can re-enable diff.external / core.pager / aliases, so a set value must skip.
      assert_stubbed env.merge("GIT_CONFIG_GLOBAL" => "/tmp/hive-evil.gitconfig"), "git", "status"
      assert_stubbed env.merge("GIT_CONFIG_SYSTEM" => "/tmp/hive-evil-system.gitconfig"), "git", "status"
      # Default-deny on a malformed GIT_CONFIG_COUNT: a non-numeric value (which `.to_i` reads
      # as 0/allowed) must be rejected rather than trusted to git's own parsing.
      assert_stubbed env.merge("GIT_CONFIG_COUNT" => "not-a-number"), "git", "status"
      assert_stubbed env, "git", "unknown-write-command"
      assert_passes env, "git", "-C", dir, "status", "--short"
      assert_passes env, "git", "config", "--get", "remote.origin.url"
      assert_passes env, "git", "config", "--get-all", "remote.origin.fetch"
      assert_passes env, "git", "config", "--list"
      # Reads with a type/format modifier before --get are still read-only;
      # auto_commit runs `git config --bool --get commit.gpgsign`.
      assert_passes env, "git", "config", "--bool", "--get", "commit.gpgsign"
      assert_passes env, "git", "config", "--int", "--get", "core.abbrev"
      assert_passes env, "git", "config", "--path", "--get", "core.excludesfile"
      assert_passes env, "git", "config", "-z", "--get-all", "remote.origin.fetch"
      assert_passes env, "git", "config", "--type=bool", "--get", "commit.gpgsign"
      assert_passes env, "git", "remote"
      assert_passes env, "git", "remote", "-v"
      assert_passes env, "git", "remote", "show", "-n", "origin"
      assert_passes env, "git", "remote", "get-url", "--push", "origin"
      assert_passes env, "git", "remote", "get-url", "--all", "origin"
      # Read-only subcommand `-p` must pass through; it is not the global `--paginate`.
      assert_passes env, "git", "log", "-p"
      assert_passes env, "git", "show", "-p"
      assert_passes env, "git", "diff", "-p"
      assert_passes env, "git", "grep", "-p", "needle"
      # `git grep -o` / `--only-matching` is a read-only match filter, not a file-write; the
      # output-file guard is scoped past grep so it stays allowed.
      assert_passes env, "git", "grep", "-o", "needle"
      assert_passes env, "git", "grep", "--only-matching", "needle"
      # `git ls-files -o` / `--others` lists untracked files — a read; the output-file guard
      # must not over-block it.
      assert_passes env, "git", "ls-files", "-o"
      assert_passes env, "git", "ls-files", "--others"
      # On diff/log/show, `-O<orderfile>` is `--output-ordering` (reads an orderfile), not the
      # grep pager flag — a cross-subcommand read that must pass through (glued and separate).
      assert_passes env, "git", "diff", "-O/tmp/hive-orderfile"
      assert_passes env, "git", "log", "-O", "/tmp/hive-orderfile"
      # After `--`, `-o` is a literal pathspec (a file named `-o`), not the output flag, so
      # the file-write guard must not over-block the read.
      assert_passes env, "git", "log", "--", "-o"
      # Empty / zero env-config vars inject nothing, so the env guard must not over-block the
      # read: GIT_CONFIG_COUNT=0 resolves to no config, and an unset external-diff is harmless.
      assert_passes env.merge("GIT_CONFIG_COUNT" => "0", "GIT_EXTERNAL_DIFF" => ""), "git", "status", "--short"

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
      assert_includes skipped, "gh auth status --show-token skipped"
      assert_includes skipped, "gh auth status -t skipped"
      assert_includes skipped, "gh auth status --json hosts --show-token skipped"
      assert_includes skipped, "gh workflow run release.yml skipped"
      assert_includes skipped, "git -C #{dir} push origin HEAD:feature skipped"
      assert_includes skipped, "git commit -m dry run must not commit skipped"
      assert_includes skipped, "git merge feature skipped"
      assert_includes skipped, "git config user.name newvalue --get skipped"
      assert_includes skipped, "git config user.email newvalue --get-all skipped"
      assert_includes skipped, "git config commit.gpgsign false --list skipped"
      assert_includes skipped, "git remote set-url origin git@example.com:owner/repo.git skipped"
      assert_includes skipped, "git remote add upstream git@example.com:owner/upstream.git skipped"
      assert_includes skipped, "git remote remove upstream skipped"
      assert_includes skipped, "git -c diff.external=touch /tmp/hive-dryrun-pwn diff skipped"
      assert_includes skipped, "git -c core.fsmonitor=touch /tmp/hive-fsmonitor-pwn status skipped"
      assert_includes skipped, "git --config-env=core.pager=HIVE_TEST_PAGER log --oneline skipped"
      assert_includes skipped, "git --paginate log --oneline skipped"
      assert_includes skipped, "git grep --open-files-in-pager=touch /tmp/hive-pager-pwn needle skipped"

      real_invocations = File.read(File.join(dir, "real.log"))
      assert_includes real_invocations, "real-gh auth status"
      assert_includes real_invocations, "real-gh auth status --active --hostname github.example.com"
      assert_includes real_invocations, "real-gh auth status --json hosts --jq .hosts"
      assert_includes real_invocations, "real-gh --repo=owner/repo pr view 42"
      assert_includes real_invocations, "real-gh api repos/owner/repo"
      assert_includes real_invocations, "real-gh api --method GET repos/owner/repo/issues -f state=open"
      assert_includes real_invocations, "real-git -C #{dir} status --short"
      assert_includes real_invocations, "real-git config --get remote.origin.url"
      assert_includes real_invocations, "real-git config --get-all remote.origin.fetch"
      assert_includes real_invocations, "real-git config --list"
      assert_includes real_invocations, "real-git config --bool --get commit.gpgsign"
      assert_includes real_invocations, "real-git config --int --get core.abbrev"
      assert_includes real_invocations, "real-git config --path --get core.excludesfile"
      assert_includes real_invocations, "real-git config -z --get-all remote.origin.fetch"
      assert_includes real_invocations, "real-git config --type=bool --get commit.gpgsign"
      assert_includes real_invocations, "real-git remote"
      assert_includes real_invocations, "real-git remote -v"
      assert_includes real_invocations, "real-git remote show -n origin"
      assert_includes real_invocations, "real-git remote get-url --push origin"
      assert_includes real_invocations, "real-git remote get-url --all origin"
      # The PR's headline regression target: `-p` must reach real git as the subcommand flag,
      # not be misclassified as the global `--paginate` and skipped.
      assert_includes real_invocations, "real-git log -p"
      assert_includes real_invocations, "real-git show -p"
      assert_includes real_invocations, "real-git diff -p"
      assert_includes real_invocations, "real-git grep -p needle"
      assert_includes real_invocations, "real-git grep -o needle"
      assert_includes real_invocations, "real-git log -- -o"
    end
  end

  private

  def assert_stubbed(env, binary, *args)
    _out, err, status = Open3.capture3(env, stub_path(binary), *args)
    assert status.success?, err
    assert_includes err, "[dry-run] #{binary} #{args.join(' ')} skipped"
    # Load-bearing: prove the command did not also fall through to the real binary. A
    # regression that logs the skip *and then* still exec's real git/gh would pass the
    # stderr check above; the absence from real.log is what actually verifies no passthrough.
    real_log = @real_log && File.exist?(@real_log) ? File.read(@real_log) : ""
    refute_includes real_log, "real-#{binary} #{args.join(' ')}",
                     "#{binary} #{args.join(' ')} was skipped but still reached real #{binary}"
  end

  def assert_passes(env, binary, *args)
    _out, err, status = Open3.capture3(env, stub_path(binary), *args)
    assert status.success?, err
    # Load-bearing, mirroring assert_stubbed's refute: exit 0 alone does not prove passthrough
    # — a "skipped-but-exit-0" regression would also exit 0. Confirm the invocation actually
    # reached the real binary by finding it in real.log.
    real_log = @real_log && File.exist?(@real_log) ? File.read(@real_log) : ""
    assert_includes real_log, "real-#{binary} #{args.join(' ')}",
                    "#{binary} #{args.join(' ')} passed (exit 0) but never reached real #{binary}"
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
