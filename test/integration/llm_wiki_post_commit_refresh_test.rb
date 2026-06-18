# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"

# Guards the worktree-safe contract of .llm-wiki/post-commit-refresh.sh: a commit
# in a linked worktree must leave that worktree's wiki/ clean and land the wiki
# refresh as a single scoped, unpushed commit on the MAIN checkout. The headless
# agent is replaced via the LLM_WIKI_REFRESH_CMD seam so no model runs.
class LlmWikiPostCommitRefreshTest < Minitest::Test
  include HiveTestHelper

  SCRIPT = File.expand_path("../../.llm-wiki/post-commit-refresh.sh", __dir__)

  def setup
    @dir = Dir.mktmpdir("llmwiki-hook-")
    @main = File.join(@dir, "main")
    @wt = File.join(@dir, "wt")
    @stub = File.join(@dir, "stub-refresh.sh")

    File.write(@stub, <<~STUB)
      #!/usr/bin/env bash
      wiki_root="$1"
      mkdir -p "$wiki_root/wiki/log.d"
      printf 'stub refresh for %s\\n' "$(git -C "$wiki_root" rev-parse --abbrev-ref HEAD)" \\
        > "$wiki_root/wiki/log.d/stub-entry.md"
    STUB
    FileUtils.chmod("+x", @stub)

    sh "git init -q -b main #{q(@main)}"
    git(@main, "config user.email t@t")
    git(@main, "config user.name t")
    git(@main, "config commit.gpgsign false")
    FileUtils.mkdir_p(File.join(@main, ".llm-wiki"))
    FileUtils.mkdir_p(File.join(@main, "wiki", "log.d"))
    FileUtils.mkdir_p(File.join(@main, "bin"))
    FileUtils.cp(SCRIPT, File.join(@main, ".llm-wiki", "post-commit-refresh.sh"))
    File.write(File.join(@main, "wiki", "index.md"), "# wiki\n")
    File.write(File.join(@main, "bin", "tool.sh"), "echo hi\n")
    git(@main, "add -A")
    git(@main, "commit -qm init")
    git(@main, "worktree add -q -b feat #{q(@wt)}")
    git(@wt, "config user.email t@t")
    git(@wt, "config user.name t")
    git(@wt, "config commit.gpgsign false")
  end

  def teardown
    # Detach worktree before removing so git metadata doesn't linger.
    git(@main, "worktree remove --force #{q(@wt)}") rescue nil
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  def test_worktree_commit_lands_wiki_on_main_and_leaves_worktree_clean
    File.write(File.join(@wt, "bin", "tool.sh"), "echo hi\necho feature\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: change bin/tool'")
    feat_head_before = git(@wt, "rev-parse HEAD")

    run_refresh_from(@wt)

    # The linked worktree's tree stays pristine — no wiki residue, nothing dirty.
    assert_equal "", git(@wt, "status --porcelain"),
                 "linked worktree must be clean after the refresh"
    # The wiki refresh landed as one scoped commit on main.
    assert_match(/docs\(wiki\): post-commit refresh/, git(@main, "log -1 --pretty=%s"),
                 "wiki refresh must be committed on the main checkout")
    assert_includes git(@main, "show --stat --pretty=format: HEAD"), "wiki/log.d/stub-entry.md",
                    "the refreshed wiki file must be in main's commit"
    # The feature branch is untouched by the refresh (no extra commit on it).
    assert_equal feat_head_before, git(@wt, "rev-parse HEAD"),
                 "the refresh must not add a commit to the feature branch"
    assert_equal "2", git(@wt, "rev-list --count HEAD"),
                 "feature branch keeps exactly init + feat"
  end

  def test_concurrent_refresh_exits_cleanly_while_lock_held
    common = git(@wt, "rev-parse --git-common-dir")
    lock = File.join(common, "llm-wiki", "refresh.lock")
    FileUtils.mkdir_p(lock) # simulate another refresh holding the lock

    File.write(File.join(@wt, "bin", "tool.sh"), "echo hi\necho more\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: more'")

    out = run_refresh_from(@wt)
    assert_equal 0, out[:status], "a refresh blocked by the lock must exit 0"
    refute_path_exists File.join(@main, "wiki", "log.d", "stub-entry.md"),
                       "no refresh work should happen while the lock is held"
  ensure
    FileUtils.rm_rf(lock) if lock
  end

  private

  def run_refresh_from(tree)
    script = File.join(tree, ".llm-wiki", "post-commit-refresh.sh")
    # Mask qmd and force the stub agent; keep PATH minimal so the real qmd
    # global index is never touched by the test.
    env = { "LLM_WIKI_REFRESH_CMD" => @stub, "PATH" => "/usr/bin:/bin", "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "" }
    out = `cd #{q(tree)} && #{env.map { |k, v| "#{k}=#{q(v)}" }.join(" ")} bash #{q(script)} 2>&1`
    { out: out, status: $?.exitstatus }
  end

  def git(dir, args)
    `git -C #{q(dir)} #{args}`.strip
  end

  def sh(cmd)
    `#{cmd}`
  end

  def q(str)
    "'#{str}'"
  end
end
