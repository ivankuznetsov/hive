# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"

# Guards the transactional contract of .llm-wiki/post-commit-refresh.sh: a
# commit in any checkout queues one refresh into a dedicated managed worktree.
# Neither the committing checkout nor the user's main checkout may be mutated.
# The headless agent is replaced via LLM_WIKI_REFRESH_CMD so no model runs.
class LlmWikiPostCommitRefreshTest < Minitest::Test
  include HiveTestHelper

  SCRIPT = File.expand_path("../../.llm-wiki/post-commit-refresh.sh", __dir__)

  def setup
    @dir = Dir.mktmpdir("llmwiki-hook-")
    @main = File.join(@dir, "main")
    @wt = File.join(@dir, "wt")
    @stub = File.join(@dir, "stub bin", "stub-refresh.sh")

    FileUtils.mkdir_p(File.dirname(@stub))
    File.write(@stub, <<~STUB)
      #!/usr/bin/env bash
      wiki_root="$1"
      mkdir -p "$wiki_root/wiki/log.d"
      printf 'stub refresh for %s\n' "$(git -C "$wiki_root" rev-parse --abbrev-ref HEAD)" \
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
    git(@main, "worktree remove --force #{q(@wt)}") rescue nil
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  def test_worktree_commit_lands_wiki_on_refresh_branch_and_leaves_user_checkouts_clean
    File.write(File.join(@wt, "bin", "tool.sh"), "echo hi\necho feature\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: change bin/tool'")
    feat_head_before = git(@wt, "rev-parse HEAD")
    main_head_before = git(@main, "rev-parse HEAD")

    run_refresh_from(@wt)

    assert_equal "", git(@wt, "status --porcelain")
    assert_equal "", git(@main, "status --porcelain")
    assert_equal main_head_before, git(@main, "rev-parse HEAD")
    assert_equal feat_head_before, git(@wt, "rev-parse HEAD")
    assert_match(/docs\(wiki\): queued refresh/, git(@main, "log -1 --pretty=%s llm-wiki/refresh"))
    assert_includes git(@main, "show --stat --pretty=format: llm-wiki/refresh"),
                    "wiki/log.d/stub-entry.md"
    assert_match(/stub refresh/, git(@main, "show llm-wiki/refresh:wiki/log.d/stub-entry.md"))
  end

  def test_concurrent_refresh_stays_queued_until_a_worker_can_acquire_the_lock
    common = git(@wt, "rev-parse --path-format=absolute --git-common-dir")
    set_refresh_lock(@wt, "#{Process.pid}|#{Time.now.to_i}||1\n")

    File.write(File.join(@wt, "bin", "tool.sh"), "echo hi\necho more\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: more'")

    out = run_refresh_from(
      @wt,
      "LLM_WIKI_LOCK_WAIT_SECONDS" => "0"
    )
    assert_equal 0, out[:status]
    refute_empty Dir.glob(File.join(common, "llm-wiki", "pending", "*"))

    set_refresh_lock(@wt, "99999999|#{Time.now.to_i - 7_200}|dead|2\n")
    run_refresh_from(@wt)
    assert_empty Dir.glob(File.join(common, "llm-wiki", "pending", "*"))
    assert_match(/stub refresh/, git(@main, "show llm-wiki/refresh:wiki/log.d/stub-entry.md"))
  ensure
    git(@wt, "update-ref -d refs/llm-wiki/refresh-lock") rescue nil
  end

  def test_malformed_stale_lock_is_reclaimed
    File.write(File.join(@wt, "bin", "tool.sh"), "echo ownerless lock source\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: ownerless lock source'")
    common = git(@wt, "rev-parse --path-format=absolute --git-common-dir")
    set_refresh_lock(@wt, "malformed\n")

    out = run_refresh_from(@wt)

    assert_equal 0, out[:status]
    assert_empty Dir.glob(File.join(common, "llm-wiki", "pending", "*"))
    assert_match(/stub refresh/, git(@main, "show llm-wiki/refresh:wiki/log.d/stub-entry.md"))
  ensure
    git(@wt, "update-ref -d refs/llm-wiki/refresh-lock") rescue nil
  end

  def test_two_stale_lock_reclaimers_never_run_refresh_agents_concurrently
    File.write(File.join(@wt, "bin", "tool.sh"), "echo cas race source\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: cas race source'")
    set_refresh_lock(@wt, "malformed\n")
    state = File.join(@dir, "concurrency")
    FileUtils.mkdir_p(state)
    concurrent_stub = File.join(@dir, "stub bin", "concurrent-refresh.sh")
    File.write(concurrent_stub, <<~STUB)
      #!/usr/bin/env bash
      set -euo pipefail
      root="$1"
      if ! mkdir "#{state}/agent-active" 2>/dev/null; then
        touch "#{state}/overlap"
        exit 18
      fi
      touch "#{state}/entered"
      while [ ! -e "#{state}/release" ]; do sleep 0.05; done
      mkdir -p "$root/wiki/log.d"
      printf 'single worker\n' >"$root/wiki/log.d/concurrent.md"
      rmdir "#{state}/agent-active"
    STUB
    FileUtils.chmod("+x", concurrent_stub)
    script = File.join(@wt, ".llm-wiki", "post-commit-refresh.sh")
    env = {
      "LLM_WIKI_REFRESH_CMD" => concurrent_stub,
      "LLM_WIKI_LOCK_WAIT_SECONDS" => "5",
      "PATH" => "/usr/bin:/bin"
    }

    pids = 2.times.map do
      Process.spawn(env, "bash", script, chdir: @wt, out: File::NULL, err: File::NULL)
    end
    100.times do
      break if File.exist?(File.join(state, "entered"))

      sleep 0.05
    end
    assert File.exist?(File.join(state, "entered")), "one reclaimer should acquire the lock"
    sleep 0.2
    FileUtils.touch(File.join(state, "release"))
    statuses = pids.map { |pid| Process.wait2(pid).last }
    pids.clear

    assert statuses.all?(&:success?)
    refute File.exist?(File.join(state, "overlap"))
    common = git(@wt, "rev-parse --path-format=absolute --git-common-dir")
    assert_empty Dir.glob(File.join(common, "llm-wiki", "pending", "*"))
  ensure
    pids&.each { |pid| Process.kill("KILL", pid) rescue nil }
    git(@wt, "update-ref -d refs/llm-wiki/refresh-lock") rescue nil
  end

  def test_committed_source_receipt_acknowledges_replayed_queue_without_running_agent
    File.write(File.join(@wt, "bin", "tool.sh"), "echo replay source\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: replay source'")
    source_sha = git(@wt, "rev-parse HEAD")
    run_refresh_from(@wt)
    refresh_head = git(@main, "rev-parse llm-wiki/refresh")
    assert_includes git(@main, "log -1 --pretty=%B llm-wiki/refresh"),
                    "LLM-Wiki-Source: #{source_sha}"
    refute_empty git(@main, "show-ref --verify refs/llm-wiki/receipts/#{source_sha}")

    common = git(@wt, "rev-parse --path-format=absolute --git-common-dir")
    pending = File.join(common, "llm-wiki", "pending")
    FileUtils.mkdir_p(pending)
    File.write(File.join(pending, source_sha), "#{source_sha}\tfeat\nbin/tool.sh\n")
    marker = File.join(@dir, "replay-agent-ran")
    replay_stub = File.join(@dir, "stub bin", "replay-refresh.sh")
    File.write(replay_stub, <<~STUB)
      #!/usr/bin/env bash
      touch #{q(marker)}
      exit 19
    STUB
    FileUtils.chmod("+x", replay_stub)

    out = run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => replay_stub)

    assert_equal 0, out[:status]
    refute File.exist?(marker)
    assert_empty Dir.glob(File.join(pending, "*"))
    assert_equal refresh_head, git(@main, "rev-parse llm-wiki/refresh")
  end

  def test_main_checkout_commit_never_creates_a_second_commit_on_main
    File.write(File.join(@main, "bin", "tool.sh"), "echo hi\necho main-change\n")
    git(@main, "add -A")
    git(@main, "commit -qm 'feat: change on main'")
    main_head_before = git(@main, "rev-parse HEAD")

    run_refresh_from(@main)

    assert_equal main_head_before, git(@main, "rev-parse HEAD")
    assert_equal "", git(@main, "status --porcelain")
    assert_match(/docs\(wiki\): queued refresh/, git(@main, "log -1 --pretty=%s llm-wiki/refresh"))
  end

  def test_dirty_main_checkout_is_byte_for_byte_untouched
    File.write(File.join(@main, "wiki", "index.md"), "# user's pending wiki edit\n")
    File.write(File.join(@main, "bin", "tool.sh"), "echo user's pending code edit\n")
    status_before = git(@main, "status --porcelain=v1")
    wiki_before = File.binread(File.join(@main, "wiki", "index.md"))
    code_before = File.binread(File.join(@main, "bin", "tool.sh"))

    File.write(File.join(@wt, "bin", "tool.sh"), "echo feature commit\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: queued refresh source'")
    run_refresh_from(@wt)

    assert_equal status_before, git(@main, "status --porcelain=v1")
    assert_equal wiki_before, File.binread(File.join(@main, "wiki", "index.md"))
    assert_equal code_before, File.binread(File.join(@main, "bin", "tool.sh"))
    assert_match(/stub refresh/, git(@main, "show llm-wiki/refresh:wiki/log.d/stub-entry.md"))
  end

  def test_failed_refresh_discards_generated_dirt_and_keeps_queue_for_retry
    failing_stub = File.join(@dir, "stub bin", "failing-refresh.sh")
    File.write(failing_stub, <<~STUB)
      #!/usr/bin/env bash
      wiki_root="$1"
      mkdir -p "$wiki_root/wiki/log.d"
      printf 'partial\n' > "$wiki_root/wiki/log.d/partial.md"
      printf 'escaped\n' > "$wiki_root/escaped.txt"
      exit 17
    STUB
    FileUtils.chmod("+x", failing_stub)

    File.write(File.join(@wt, "bin", "tool.sh"), "echo failed refresh source\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: failing refresh source'")
    common = git(@wt, "rev-parse --path-format=absolute --git-common-dir")

    out = run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => failing_stub)

    assert_equal 0, out[:status], "post-commit maintenance must not fail the source commit"
    assert_equal "", git(@wt, "status --porcelain")
    refute_empty Dir.glob(File.join(common, "llm-wiki", "pending", "*"))
    refute_includes git(@main, "worktree list --porcelain"),
                    File.join(common, "llm-wiki", "refresh-worktree")
    refute File.exist?(File.join(@main, "escaped.txt"))
  end

  def test_recursion_guards_present_in_script
    script = File.read(SCRIPT)
    assert_match(/core\.hooksPath=\/dev\/null/, script)
    assert_match(/HIVE_SKIP_LLM_WIKI_POST_COMMIT=1 \\\n+\s*git -C "\$refresh_root"/, script)
    refute_match(/git .*push/, script)
    refute_match(/wiki_root="\$main_checkout"/, script)
  end

  def test_generated_scripts_match_committed_and_template_copies
    require "hive/llm_wiki_bootstrap/scripts"
    root = File.expand_path("../..", __dir__)
    {
      "post-commit-refresh.sh" => Hive::LlmWikiBootstrap::Scripts.post_commit_refresh,
      "compile-log.sh" => Hive::LlmWikiBootstrap::Scripts.compile_log
    }.each do |name, generated|
      committed = File.read(File.join(root, ".llm-wiki", name))
      template = File.read(File.join(root, "templates", "llm-wiki", name))
      assert_equal template, generated
      assert_equal template, committed
    end
  end

  private

  def run_refresh_from(tree, overrides = {})
    script = File.join(tree, ".llm-wiki", "post-commit-refresh.sh")
    env = {
      "LLM_WIKI_REFRESH_CMD" => @stub,
      "PATH" => "/usr/bin:/bin",
      "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "",
      "LLM_WIKI_LOCK_WAIT_SECONDS" => "5"
    }.merge(overrides)
    out = `cd #{q(tree)} && #{env.map { |k, v| "#{k}=#{q(v)}" }.join(" ")} bash #{q(script)} 2>&1`
    { out: out, status: $?.exitstatus }
  end

  def set_refresh_lock(tree, owner)
    owner_path = File.join(@dir, "refresh-lock-owner")
    File.write(owner_path, owner)
    oid = git(tree, "hash-object -w #{q(owner_path)}")
    git(tree, "update-ref refs/llm-wiki/refresh-lock #{oid}")
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
