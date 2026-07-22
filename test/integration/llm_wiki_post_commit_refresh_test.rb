# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require "open3"

# Guards the transactional contract of .llm-wiki/post-commit-refresh.sh: a
# commit in any checkout queues one refresh into a dedicated managed worktree.
# Neither the committing checkout nor the user's main checkout may be mutated.
# The headless agent is replaced via LLM_WIKI_REFRESH_CMD so no model runs.
class LlmWikiPostCommitRefreshTest < Minitest::Test
  include HiveTestHelper

  SCRIPT = File.expand_path("../../.llm-wiki/post-commit-refresh.sh", __dir__)
  SCHEDULED_SCRIPT = File.expand_path("../../.llm-wiki/refresh-wiki.sh", __dir__)

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

  def test_refresh_branch_is_pushed_without_touching_main
    remote = File.join(@dir, "remote.git")
    sh "git init -q --bare #{q(remote)}"
    git(@main, "remote add origin #{q(remote)}")
    git(@main, "push -q -u origin main")
    File.write(File.join(@wt, "bin", "tool.sh"), "echo pushed refresh\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: push wiki source'")
    main_head_before = git(@main, "rev-parse HEAD")

    result = run_refresh_from(@wt)

    assert_equal 0, result.fetch(:status), result.fetch(:out)
    local_refresh = git(@main, "rev-parse llm-wiki/refresh")
    remote_refresh = `git --git-dir=#{q(remote)} rev-parse refs/heads/llm-wiki/refresh`.strip
    assert_equal local_refresh, remote_refresh
    assert_equal main_head_before, git(@main, "rev-parse HEAD")
    assert_equal "", git(@main, "status --porcelain")
  end

  def test_rejected_refresh_push_keeps_commit_and_queue_without_opening_circuit_then_recovers
    remote = File.join(@dir, "rejecting-remote.git")
    sh "git init -q --bare #{q(remote)}"
    git(@main, "remote add origin #{q(remote)}")
    git(@main, "push -q -u origin main")
    hook = File.join(remote, "hooks", "pre-receive")
    File.write(hook, <<~HOOK)
      #!/usr/bin/env bash
      while read -r _old _new ref; do
        [ "$ref" != "refs/heads/llm-wiki/refresh" ] || exit 1
      done
    HOOK
    FileUtils.chmod("+x", hook)
    calls = File.join(@dir, "rejecting-agent-calls")
    counting_stub = File.join(@dir, "stub bin", "counting-refresh.sh")
    File.write(counting_stub, <<~STUB)
      #!/usr/bin/env bash
      root="$1"
      printf 'called\n' >>#{q(calls)}
      mkdir -p "$root/wiki/log.d"
      printf 'retained publication\n' >"$root/wiki/log.d/rejected.md"
    STUB
    FileUtils.chmod("+x", counting_stub)
    File.write(File.join(@wt, "bin", "tool.sh"), "echo rejected refresh\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: retain rejected wiki source'")
    source_sha = git(@wt, "rev-parse HEAD")
    main_head_before = git(@main, "rev-parse HEAD")

    result = run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => counting_stub)
    File.write(File.join(@wt, "bin", "tool.sh"), "echo rejected refresh\necho newly queued source\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: queue source behind retained publication'")
    second_sha = git(@wt, "rev-parse HEAD")
    second_result = run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => counting_stub)

    assert_equal 0, result.fetch(:status), result.fetch(:out)
    assert_equal 0, second_result.fetch(:status), second_result.fetch(:out)
    common = git(@main, "rev-parse --path-format=absolute --git-common-dir")
    assert_path_exists File.join(common, "llm-wiki", "pending", source_sha)
    assert_path_exists File.join(common, "llm-wiki", "pending", second_sha)
    refute_path_exists File.join(common, "llm-wiki", "refresh-disabled")
    refute_path_exists File.join(common, "llm-wiki", "consecutive-failures")
    assert_equal 1, File.readlines(calls).length, "publication retry must not rerun the agent"
    assert_equal main_head_before, git(@main, "rev-parse HEAD")
    assert_equal "", git(@main, "status --porcelain")
    assert_match(/LLM-Wiki-Source: #{source_sha}/, git(@main, "log --format=%B llm-wiki/refresh"))

    FileUtils.rm_f(hook)
    recovery = run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => counting_stub)

    assert_equal 0, recovery.fetch(:status), recovery.fetch(:out)
    assert_equal 2, File.readlines(calls).length,
                 "recovery should publish the retained source and run the agent only for new work"
    refute_path_exists File.join(common, "llm-wiki", "pending", source_sha)
    refute_path_exists File.join(common, "llm-wiki", "pending", second_sha)
    remote_refresh = `git --git-dir=#{q(remote)} rev-parse refs/heads/llm-wiki/refresh`.strip
    assert_equal git(@main, "rev-parse llm-wiki/refresh"), remote_refresh
    assert_match(/LLM-Wiki-Source: #{source_sha}/,
                 `git --git-dir=#{q(remote)} log --format=%B refs/heads/llm-wiki/refresh`)
    assert_match(/LLM-Wiki-Source: #{second_sha}/,
                 `git --git-dir=#{q(remote)} log --format=%B refs/heads/llm-wiki/refresh`)
  end

  def test_noop_generation_creates_publishable_acknowledgement_and_does_not_rerun_agent
    remote = File.join(@dir, "noop-rejecting-remote.git")
    sh "git init -q --bare #{q(remote)}"
    git(@main, "remote add origin #{q(remote)}")
    git(@main, "push -q -u origin main")
    hook = File.join(remote, "hooks", "pre-receive")
    File.write(hook, "#!/bin/sh\nexit 1\n")
    FileUtils.chmod("+x", hook)
    calls = File.join(@dir, "noop-agent-calls")
    noop_stub = File.join(@dir, "stub bin", "noop-refresh.sh")
    File.write(noop_stub, "#!/bin/sh\nprintf 'called\\n' >>#{q(calls)}\n")
    FileUtils.chmod("+x", noop_stub)
    File.write(File.join(@wt, "bin", "tool.sh"), "echo noop source\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: noop wiki source'")
    source_sha = git(@wt, "rev-parse HEAD")

    run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => noop_stub)
    run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => noop_stub)

    assert_equal 1, File.readlines(calls).length
    assert_match(/LLM-Wiki-Source: #{source_sha}/, git(@main, "log -1 --format=%B llm-wiki/refresh"))
  end

  def test_local_receipt_is_revalidated_after_remote_refresh_branch_disappears
    remote = File.join(@dir, "receipt-remote.git")
    sh "git init -q --bare #{q(remote)}"
    git(@main, "remote add origin #{q(remote)}")
    git(@main, "push -q -u origin main")
    calls = File.join(@dir, "receipt-agent-calls")
    counting_stub = File.join(@dir, "stub bin", "receipt-refresh.sh")
    File.write(counting_stub, <<~STUB)
      #!/bin/sh
      root="$1"
      printf 'called\n' >>#{q(calls)}
      mkdir -p "$root/wiki/log.d"
      printf 'receipt publication\n' >"$root/wiki/log.d/receipt.md"
    STUB
    FileUtils.chmod("+x", counting_stub)
    File.write(File.join(@wt, "bin", "tool.sh"), "echo receipt source\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: receipt source'")
    source_sha = git(@wt, "rev-parse HEAD")
    run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => counting_stub)
    git(@main, "push origin :refs/heads/llm-wiki/refresh")
    common = git(@main, "rev-parse --path-format=absolute --git-common-dir")
    pending = File.join(common, "llm-wiki", "pending", source_sha)
    File.write(pending, "#{source_sha}\tfeat\nbin/tool.sh\n")
    git(@main, "update-ref refs/llm-wiki/sources/#{source_sha} #{source_sha}")

    result = run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => counting_stub)

    assert_equal 0, result.fetch(:status), result.fetch(:out)
    assert_equal 1, File.readlines(calls).length,
                 "remote receipt recovery should republish without another agent run"
    refute_path_exists pending
    assert system("git", "--git-dir=#{remote}", "show-ref", "--verify", "refs/heads/llm-wiki/refresh")
  end

  def test_refresh_merge_conflict_opens_durable_publication_block_without_rerunning_agent
    remote = File.join(@dir, "conflicting-remote.git")
    other = File.join(@dir, "conflicting-clone")
    sh "git init -q --bare #{q(remote)}"
    git(@main, "remote add origin #{q(remote)}")
    git(@main, "push -q -u origin main")

    File.write(File.join(@wt, "bin", "tool.sh"), "echo establish refresh branch\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: establish refresh branch'")
    run_refresh_from(@wt)

    hook = File.join(remote, "hooks", "pre-receive")
    File.write(hook, <<~HOOK)
      #!/usr/bin/env bash
      while read -r _old _new ref; do
        [ "$ref" != "refs/heads/llm-wiki/refresh" ] || exit 1
      done
    HOOK
    FileUtils.chmod("+x", hook)
    calls = File.join(@dir, "conflict-agent-calls")
    conflict_stub = File.join(@dir, "stub bin", "conflict-refresh.sh")
    File.write(conflict_stub, <<~STUB)
      #!/usr/bin/env bash
      root="$1"
      printf 'called\n' >>#{q(calls)}
      printf 'local publication\n' >"$root/wiki/conflict.md"
    STUB
    FileUtils.chmod("+x", conflict_stub)

    File.write(File.join(@wt, "bin", "tool.sh"), "echo local unpublished refresh\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: retain conflicting refresh'")
    source_sha = git(@wt, "rev-parse HEAD")
    run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => conflict_stub)
    FileUtils.rm_f(hook)

    sh "git clone -q #{q(remote)} #{q(other)}"
    git(other, "config user.email other@t")
    git(other, "config user.name other")
    git(other, "checkout -q main")
    git(other, "checkout -q llm-wiki/refresh")
    File.write(File.join(other, "wiki", "conflict.md"), "remote publication\n")
    git(other, "add wiki/conflict.md")
    git(other, "commit -qm 'docs(wiki): conflicting remote publication'")
    git(other, "push -q origin llm-wiki/refresh")

    first_retry = run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => conflict_stub)
    second_retry = run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => conflict_stub)

    assert_equal 0, first_retry.fetch(:status), first_retry.fetch(:out)
    assert_equal 0, second_retry.fetch(:status), second_retry.fetch(:out)
    common = git(@main, "rev-parse --path-format=absolute --git-common-dir")
    marker = File.join(common, "llm-wiki", "publication-blocked")
    assert_path_exists marker
    assert_includes File.read(marker), "description=origin/llm-wiki/refresh"
    assert_path_exists File.join(common, "llm-wiki", "pending", source_sha)
    assert_equal 1, File.readlines(calls).length,
                 "a durable publication conflict must suppress repeated agent runs"
  end

  def test_published_refresh_history_survives_later_default_branch_changes
    remote = File.join(@dir, "history-remote.git")
    other = File.join(@dir, "history-clone")
    sh "git init -q --bare #{q(remote)}"
    git(@main, "remote add origin #{q(remote)}")
    git(@main, "push -q -u origin main")
    source_stub = write_source_named_stub("history-refresh.sh")

    File.write(File.join(@wt, "bin", "tool.sh"), "echo first source\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: first published source'")
    first_source = git(@wt, "rev-parse HEAD")
    run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => source_stub)

    sh "git clone -q #{q(remote)} #{q(other)}"
    git(other, "config user.email other@t")
    git(other, "config user.name other")
    git(other, "checkout -q main")
    File.write(File.join(other, "README.md"), "# remotely advanced main\n")
    git(other, "add README.md")
    git(other, "commit -qm 'docs: remotely advance main'")
    git(other, "push -q origin main")
    remote_main = git(other, "rev-parse HEAD")

    File.write(File.join(@wt, "bin", "tool.sh"), "echo source after remote main\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: source after remote main'")
    second_source = git(@wt, "rev-parse HEAD")
    result = run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => source_stub)

    assert_equal 0, result.fetch(:status), result.fetch(:out)
    remote_log = `git --git-dir=#{q(remote)} log --format=%B refs/heads/llm-wiki/refresh`
    assert_match(/LLM-Wiki-Source: #{first_source}/, remote_log)
    assert_match(/LLM-Wiki-Source: #{second_source}/, remote_log)
    assert system("git", "--git-dir=#{remote}", "merge-base", "--is-ancestor",
                  remote_main, "refs/heads/llm-wiki/refresh")
  end

  def test_commit_trigger_dispatches_to_memory_bounded_scheduler_when_available
    common = git(@wt, "rev-parse --path-format=absolute --git-common-dir")
    state_dir = File.join(common, "llm-wiki")
    fake_bin = File.join(@dir, "systemctl-bin")
    calls = File.join(@dir, "systemctl-calls")
    FileUtils.mkdir_p(state_dir)
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(state_dir, "scheduler-service"), "llm-wiki-project-deadbeef.service\n")
    File.write(File.join(fake_bin, "systemctl"), <<~SH)
      #!/bin/sh
      printf '%s\n' "$*" >>#{q(calls)}
    SH
    FileUtils.chmod("+x", File.join(fake_bin, "systemctl"))
    File.write(File.join(@wt, "bin", "tool.sh"), "echo scheduled source\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: dispatch scheduled wiki worker'")
    source_sha = git(@wt, "rev-parse HEAD")

    result = run_refresh_from(
      @wt,
      "PATH" => "#{fake_bin}:/usr/bin:/bin",
      "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "0"
    )

    assert_equal 0, result.fetch(:status), result.fetch(:out)
    assert_equal "--user start --no-block llm-wiki-project-deadbeef.service\n", File.read(calls)
    assert_path_exists File.join(state_dir, "pending", source_sha)
    refute system("git", "-C", @main, "show-ref", "--verify", "--quiet", "refs/heads/llm-wiki/refresh")
  end

  def test_failed_systemd_dispatch_removes_marker_and_uses_serialized_fallback
    common = git(@wt, "rev-parse --path-format=absolute --git-common-dir")
    state_dir = File.join(common, "llm-wiki")
    fake_bin = File.join(@dir, "failing-systemctl-bin")
    FileUtils.mkdir_p(state_dir)
    FileUtils.mkdir_p(fake_bin)
    marker = File.join(state_dir, "scheduler-service")
    File.write(marker, "llm-wiki-project-deadbeef.service\n")
    File.write(File.join(fake_bin, "systemctl"), "#!/bin/sh\nexit 1\n")
    FileUtils.chmod("+x", File.join(fake_bin, "systemctl"))
    File.write(File.join(@wt, "bin", "tool.sh"), "echo fallback source\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: fall back from unavailable systemd'")

    result = run_refresh_from(
      @wt,
      "PATH" => "#{fake_bin}:/usr/bin:/bin",
      "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "0"
    )

    assert_equal 0, result.fetch(:status), result.fetch(:out)
    refute_path_exists marker
    assert_match(/stub refresh/, git(@main, "show llm-wiki/refresh:wiki/log.d/stub-entry.md"))
  end

  def test_ruby_portable_global_lock_respects_an_existing_os_lock
    runtime_dir = File.join(@dir, "runtime")
    lock_file = File.join(runtime_dir, "hive-llm-wiki-refresh.lock")
    ready = File.join(runtime_dir, "holder-ready")
    forbidden_setup = File.join(runtime_dir, "forbidden-bundler-setup.rb")
    FileUtils.mkdir_p(runtime_dir)
    File.write(forbidden_setup, "raise 'inherited Bundler setup reached portable lock keeper'\n")
    holder = Process.spawn(
      "ruby", "-e",
      "f=File.open(ARGV[0], File::RDWR|File::CREAT, 0600); f.flock(File::LOCK_EX); File.write(ARGV[1], 'ready'); sleep 60",
      lock_file, ready,
      out: File::NULL, err: File::NULL
    )
    sleep 0.01 until File.exist?(ready)
    File.write(File.join(@wt, "bin", "tool.sh"), "echo portable lock source\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: portable lock source'")
    source_sha = git(@wt, "rev-parse HEAD")

    result = run_refresh_from(
      @wt,
      "XDG_RUNTIME_DIR" => runtime_dir,
      "LLM_WIKI_DISABLE_FLOCK" => "1",
      "RUBYOPT" => "-rbundler/setup",
      "BUNDLER_SETUP" => forbidden_setup
    )

    assert_equal 0, result.fetch(:status), result.fetch(:out)
    common = git(@main, "rev-parse --path-format=absolute --git-common-dir")
    assert_path_exists File.join(common, "llm-wiki", "pending", source_sha)
    refute system("git", "-C", @main, "show-ref", "--verify", "--quiet", "refs/heads/llm-wiki/refresh")

    Process.kill("TERM", holder)
    Process.wait(holder)
    holder = nil
    pending = File.join(common, "llm-wiki", "pending", source_sha)
    recovery = nil
    3.times do
      recovery = run_refresh_from(
        @wt,
        "XDG_RUNTIME_DIR" => runtime_dir,
        "LLM_WIKI_DISABLE_FLOCK" => "1",
        "RUBYOPT" => "-rbundler/setup",
        "BUNDLER_SETUP" => forbidden_setup
      )
      break unless File.exist?(pending)

      sleep 0.05
    end
    assert_equal 0, recovery.fetch(:status), recovery.fetch(:out)
    log = File.read(File.join(common, "llm-wiki", "post-commit-refresh.log"))
    refute_path_exists pending, "queue did not recover after lock release:\n#{recovery.fetch(:out)}\n#{log}"
  ensure
    Process.kill("KILL", holder) rescue nil if holder
    Process.wait(holder) rescue nil if holder
  end

  def test_scheduled_worker_drains_source_queued_during_its_active_batch
    common = git(@wt, "rev-parse --path-format=absolute --git-common-dir")
    state_dir = File.join(common, "llm-wiki")
    fake_bin = File.join(@dir, "redrain-systemctl-bin")
    systemctl_calls = File.join(@dir, "redrain-systemctl-calls")
    agent_calls = File.join(@dir, "redrain-agent-calls")
    injected = File.join(@dir, "redrain-injected")
    FileUtils.mkdir_p(state_dir)
    FileUtils.mkdir_p(fake_bin)
    File.write(File.join(state_dir, "scheduler-service"), "llm-wiki-project-deadbeef.service\n")
    File.write(File.join(fake_bin, "systemctl"), <<~SH)
      #!/bin/sh
      printf '%s\n' "$*" >>#{q(systemctl_calls)}
    SH
    FileUtils.chmod("+x", File.join(fake_bin, "systemctl"))
    File.write(File.join(@wt, "bin", "tool.sh"), "echo first drain source\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: first drain source'")
    run_refresh_from(
      @wt,
      "PATH" => "#{fake_bin}:/usr/bin:/bin",
      "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "0"
    )
    redrain_stub = File.join(@dir, "stub bin", "redrain-refresh.sh")
    File.write(redrain_stub, <<~STUB)
      #!/usr/bin/env bash
      root="$1"
      printf 'called\n' >>#{q(agent_calls)}
      if [ ! -e #{q(injected)} ]; then
        touch #{q(injected)}
        printf 'echo second drain source\n' >#{q(File.join(@wt, "bin", "tool.sh"))}
        git -C #{q(@wt)} add bin/tool.sh
        git -C #{q(@wt)} -c core.hooksPath=/dev/null commit -qm 'feat: second drain source'
        PATH=#{q("#{fake_bin}:/usr/bin:/bin")} HIVE_SKIP_LLM_WIKI_SYSTEMCTL=0 \
          bash #{q(SCRIPT)} --project #{q(@wt)}
      fi
      mkdir -p "$root/wiki/log.d"
      count="$(wc -l <#{q(agent_calls)})"
      printf 'drain batch %s\n' "$count" >"$root/wiki/log.d/drain-$count.md"
    STUB
    FileUtils.chmod("+x", redrain_stub)

    env = {
      "LLM_WIKI_REFRESH_CMD" => redrain_stub,
      "PATH" => "#{fake_bin}:/usr/bin:/bin",
      "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "",
      "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "0",
      "LLM_WIKI_GLOBAL_LOCK_HELD" => "1",
      "LLM_WIKI_DRAIN_SETTLE_SECONDS" => "0"
    }
    out, err, status = Open3.capture3(env, "bash", SCRIPT, "--project", @main, "--drain", chdir: @main)

    assert status.success?, "#{out}\n#{err}"
    assert_equal 2, File.readlines(agent_calls).length
    assert_empty Dir.glob(File.join(state_dir, "pending", "*"))
    refute_path_exists File.join(state_dir, "refresh-disabled")
  end

  def test_remote_refresh_advanced_by_another_clone_is_merged_not_overwritten
    remote = File.join(@dir, "shared-remote.git")
    other = File.join(@dir, "other-clone")
    sh "git init -q --bare #{q(remote)}"
    git(@main, "remote add origin #{q(remote)}")
    git(@main, "push -q -u origin main")
    source_stub = write_source_named_stub("shared-refresh.sh")

    File.write(File.join(@wt, "bin", "tool.sh"), "echo local source\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: local source'")
    run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => source_stub)

    sh "git clone -q #{q(remote)} #{q(other)}"
    git(other, "config user.email other@t")
    git(other, "config user.name other")
    git(other, "checkout -q llm-wiki/refresh")
    File.write(File.join(other, "wiki", "other.md"), "# other clone\n")
    git(other, "add wiki/other.md")
    git(other, "commit -qm 'docs(wiki): concurrent remote update'")
    other_head = git(other, "rev-parse HEAD")
    git(other, "push -q origin llm-wiki/refresh")

    File.write(File.join(@wt, "bin", "tool.sh"), "echo local source\necho next\n")
    git(@wt, "add -A")
    git(@wt, "commit -qm 'feat: source after remote update'")
    result = run_refresh_from(@wt, "LLM_WIKI_REFRESH_CMD" => source_stub)

    assert_equal 0, result.fetch(:status), result.fetch(:out)
    remote_head = `git --git-dir=#{q(remote)} rev-parse refs/heads/llm-wiki/refresh`.strip
    assert system("git", "--git-dir=#{remote}", "merge-base", "--is-ancestor", other_head, remote_head)
    assert_equal "# other clone", `git --git-dir=#{q(remote)} show #{remote_head}:wiki/other.md`.strip
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
    assert_match(/push "\$refresh_remote" "HEAD:refs\/heads\/\$refresh_branch"/, script)
    refute_match(/wiki_root="\$main_checkout"/, script)
  end

  def test_scheduled_wrapper_delegates_to_shared_drain_runner_without_touching_dirty_checkout
    common = git(@main, "rev-parse --path-format=absolute --git-common-dir")
    shared_runner = File.join(common, "llm-wiki", "post-commit-refresh.sh")
    args_log = File.join(@dir, "scheduled-args")
    provider_marker = File.join(@dir, "provider-ran")
    fake_bin = File.join(@dir, "scheduled-bin")
    FileUtils.mkdir_p(File.dirname(shared_runner))
    FileUtils.mkdir_p(fake_bin)
    File.write(shared_runner, <<~RUNNER)
      #!/usr/bin/env bash
      # LLM_WIKI_RUNNER_CAPABILITIES: drain
      printf '%s\n' "$@" > "$LLM_WIKI_TEST_ARGS_LOG"
    RUNNER
    FileUtils.chmod("+x", shared_runner)
    File.write(File.join(fake_bin, "codex"), <<~PROVIDER)
      #!/usr/bin/env bash
      touch "$LLM_WIKI_TEST_PROVIDER_MARKER"
      exit 99
    PROVIDER
    FileUtils.chmod("+x", File.join(fake_bin, "codex"))
    FileUtils.cp(SCHEDULED_SCRIPT, File.join(@main, ".llm-wiki", "refresh-wiki.sh"))

    File.write(File.join(@main, "wiki", "index.md"), "# user's pending wiki edit\n")
    File.write(File.join(@main, "untracked.txt"), "user work\n")
    status_before = git(@main, "status --porcelain=v1")
    wiki_before = File.binread(File.join(@main, "wiki", "index.md"))

    env = {
      "HOME" => File.join(@dir, "home"),
      "PATH" => [ fake_bin, "/usr/bin", "/bin" ].join(File::PATH_SEPARATOR),
      "LLM_WIKI_TEST_ARGS_LOG" => args_log,
      "LLM_WIKI_TEST_PROVIDER_MARKER" => provider_marker
    }
    command = env.map { |key, value| "#{key}=#{q(value)}" }.join(" ")
    `cd #{q(@main)} && #{command} bash .llm-wiki/refresh-wiki.sh 2>&1`

    assert_predicate $CHILD_STATUS, :success?
    assert_equal [ "--project", @main, "--drain" ], File.readlines(args_log, chomp: true)
    assert_equal status_before, git(@main, "status --porcelain=v1")
    assert_equal wiki_before, File.binread(File.join(@main, "wiki", "index.md"))
    refute File.exist?(provider_marker), "the scheduled wrapper must not launch a provider itself"
  end

  def test_scheduled_empty_drain_uses_real_runner_without_provider_or_checkout_writes
    provider_marker = File.join(@dir, "empty-drain-provider-ran")
    provider = File.join(@dir, "empty-drain-provider.sh")
    File.write(provider, <<~PROVIDER)
      #!/usr/bin/env bash
      touch "$LLM_WIKI_TEST_PROVIDER_MARKER"
      exit 99
    PROVIDER
    FileUtils.chmod("+x", provider)
    FileUtils.cp(SCHEDULED_SCRIPT, File.join(@main, ".llm-wiki", "refresh-wiki.sh"))

    File.write(File.join(@main, "wiki", "index.md"), "# user's pending wiki edit\n")
    File.write(File.join(@main, "untracked.txt"), "user work\n")
    status_before = git(@main, "status --porcelain=v1")
    wiki_before = File.binread(File.join(@main, "wiki", "index.md"))
    env = {
      "HOME" => File.join(@dir, "home"),
      "PATH" => "/usr/bin:/bin",
      "LLM_WIKI_REFRESH_CMD" => provider,
      "LLM_WIKI_TEST_PROVIDER_MARKER" => provider_marker,
      "LLM_WIKI_LOCK_WAIT_SECONDS" => "5"
    }
    command = env.map { |key, value| "#{key}=#{q(value)}" }.join(" ")

    `cd #{q(@main)} && #{command} bash .llm-wiki/refresh-wiki.sh 2>&1`

    assert_predicate $CHILD_STATUS, :success?
    assert_equal status_before, git(@main, "status --porcelain=v1")
    assert_equal wiki_before, File.binread(File.join(@main, "wiki", "index.md"))
    refute File.exist?(provider_marker), "an empty scheduled drain must not launch the provider"
    refute_match(/refs\/heads\/llm-wiki\/refresh/, git(@main, "show-ref"))
  end

  def test_scheduled_wrapper_falls_back_to_project_runner
    common = git(@main, "rev-parse --path-format=absolute --git-common-dir")
    FileUtils.rm_f(File.join(common, "llm-wiki", "post-commit-refresh.sh"))
    args_log = File.join(@dir, "fallback-args")
    project_runner = File.join(@main, ".llm-wiki", "post-commit-refresh.sh")
    File.write(project_runner, <<~RUNNER)
      #!/usr/bin/env bash
      # LLM_WIKI_RUNNER_CAPABILITIES: drain
      printf '%s\n' "$@" > "$LLM_WIKI_TEST_ARGS_LOG"
    RUNNER
    FileUtils.chmod("+x", project_runner)
    FileUtils.cp(SCHEDULED_SCRIPT, File.join(@main, ".llm-wiki", "refresh-wiki.sh"))

    `cd #{q(@main)} && LLM_WIKI_TEST_ARGS_LOG=#{q(args_log)} bash .llm-wiki/refresh-wiki.sh 2>&1`

    assert_predicate $CHILD_STATUS, :success?
    assert_equal [ "--project", @main, "--drain" ], File.readlines(args_log, chomp: true)
  end

  def test_scheduled_wrapper_refuses_runner_without_drain_capability
    common = git(@main, "rev-parse --path-format=absolute --git-common-dir")
    FileUtils.rm_f(File.join(common, "llm-wiki", "post-commit-refresh.sh"))
    provider_marker = File.join(@dir, "legacy-runner-ran")
    project_runner = File.join(@main, ".llm-wiki", "post-commit-refresh.sh")
    File.write(project_runner, <<~RUNNER)
      #!/usr/bin/env bash
      touch "$LLM_WIKI_TEST_PROVIDER_MARKER"
    RUNNER
    FileUtils.chmod("+x", project_runner)
    FileUtils.cp(SCHEDULED_SCRIPT, File.join(@main, ".llm-wiki", "refresh-wiki.sh"))

    output = `cd #{q(@main)} && LLM_WIKI_TEST_PROVIDER_MARKER=#{q(provider_marker)} bash .llm-wiki/refresh-wiki.sh 2>&1`

    refute_predicate $CHILD_STATUS, :success?
    assert_includes output, "no drain-capable transactional refresh runner was found"
    refute File.exist?(provider_marker), "a legacy runner must never receive the scheduled drain"
  end

  def test_generated_scripts_match_committed_and_template_copies
    require "hive/llm_wiki_bootstrap/scripts"
    root = File.expand_path("../..", __dir__)
    {
      "refresh-wiki.sh" => Hive::LlmWikiBootstrap::Scripts.refresh_wiki,
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

  def write_source_named_stub(name)
    path = File.join(@dir, "stub bin", name)
    File.write(path, <<~STUB)
      #!/usr/bin/env bash
      root="$1"
      prompt="$2"
      source_sha="$(printf '%s' "$prompt" | sed -nE 's/^- commit ([0-9a-f]+).*/\\1/p' | tail -n 1)"
      mkdir -p "$root/wiki/log.d"
      printf 'stub refresh for %s\n' "$source_sha" >"$root/wiki/log.d/$source_sha.md"
    STUB
    FileUtils.chmod("+x", path)
    path
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
