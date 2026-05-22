require "open3"
require "fileutils"
require "hive/stages"

module Hive
  class GitOps
    HIVE_BRANCH = "hive/state".freeze

    attr_reader :project_root

    def initialize(project_root)
      @project_root = File.expand_path(project_root)
    end

    def hive_state_path
      File.join(@project_root, ".hive-state")
    end

    def default_branch
      @default_branch ||= detect_default_branch
    end

    def head_sha
      run_git!("-C", @project_root, "rev-parse", "HEAD").strip
    end

    def status_short
      out, err, status = Open3.capture3("git", "-C", @project_root, "status", "--short")
      raise GitError, "git -C #{@project_root} status --short failed: #{err.strip.empty? ? out : err}" unless status.success?

      out
    end

    def current_branch
      branch = run_git!("-C", @project_root, "branch", "--show-current").strip
      branch.empty? ? nil : branch
    end

    def ancestor?(ancestor, descendant)
      _out, err, status = Open3.capture3("git", "-C", @project_root, "merge-base", "--is-ancestor",
                                         ancestor, descendant)
      return true if status.success?
      return false if status.exitstatus == 1

      raise GitError, "git -C #{@project_root} merge-base --is-ancestor failed: #{err}"
    end

    def ref_exists?(ref)
      _out, _err, status = Open3.capture3("git", "-C", @project_root,
                                          "rev-parse", "--verify", "--quiet", ref)
      status.success?
    end

    def hive_state_branch_exists?
      out, _err, status = Open3.capture3("git", "-C", @project_root, "show-ref", "--verify",
                                         "refs/heads/#{HIVE_BRANCH}")
      status.success? && !out.empty?
    end

    def hive_state_worktree_exists?
      File.directory?(File.join(hive_state_path, ".git")) ||
        File.exist?(File.join(hive_state_path, ".git"))
    end

    def hive_state_init
      if hive_state_branch_exists?
        ensure_hive_state_worktree_attached
        return :existed
      end

      # Pre-flight: worktree-add requires a reachable ref. A freshly init'd
      # repo with zero commits has no <default_branch> ref and would fail
      # mid-init with a partial state.
      _, _, head_ok = Open3.capture3("git", "-C", @project_root, "rev-parse", "--verify", "HEAD")
      raise GitError, "hive init requires at least one commit on #{default_branch}" unless head_ok.success?

      run_git!("-C", @project_root, "worktree", "add", "--no-checkout", "--detach",
               hive_state_path, default_branch)
      run_git!("-C", hive_state_path, "checkout", "--orphan", HIVE_BRANCH)
      run_git_quiet("-C", hive_state_path, "rm", "-rf", ".")
      FileUtils.rm_rf(Dir.glob(File.join(hive_state_path, "*")))
      FileUtils.rm_rf(Dir.glob(File.join(hive_state_path, ".[!.]*")).reject { |p| File.basename(p) == ".git" })

      Hive::Stages::DIRS.each do |stage|
        d = File.join(hive_state_path, "stages", stage)
        FileUtils.mkdir_p(d)
        File.write(File.join(d, ".gitkeep"), "")
      end
      logs_dir = File.join(hive_state_path, "logs")
      FileUtils.mkdir_p(logs_dir)
      File.write(File.join(logs_dir, ".gitkeep"), "")

      File.write(File.join(hive_state_path, ".gitignore"), HIVE_STATE_GITIGNORE)

      run_git!("-C", hive_state_path, "add", ".")
      run_git!("-C", hive_state_path, "commit", "-m", "hive: bootstrap")
      :created
    end

    # Per-task and per-project lock metadata. PIDs and process_start_time
    # values are local to each process invocation; tracking them in
    # hive/state would commit lock state into history every `hive run` and
    # `hive approve`. The patterns below match each lock-file location.
    HIVE_STATE_GITIGNORE = <<~GITIGNORE.freeze
      # Per-task lock metadata (Hive::Lock.with_task_lock).
      stages/*/*/.lock
      stages/*/*/.lock.tmp.*

      # Per-marker atomic-write lock (Hive::Markers).
      stages/*/*/*.markers-lock

      # Per-project commit lock (Hive::Lock.with_commit_lock).
      .commit-lock
    GITIGNORE

    def ensure_hive_state_worktree_attached
      return if hive_state_worktree_exists?

      run_git!("-C", @project_root, "worktree", "add", hive_state_path, HIVE_BRANCH)
    end

    def add_hive_state_to_master_gitignore!
      gitignore_path = File.join(@project_root, ".gitignore")
      pattern = "/.hive-state/"
      existing = File.exist?(gitignore_path) ? File.read(gitignore_path) : ""
      return :already if existing.split("\n").include?(pattern)

      separator = existing.empty? || existing.end_with?("\n") ? "" : "\n"
      File.write(gitignore_path, "#{existing}#{separator}#{pattern}\n")
      run_git!("-C", @project_root, "add", ".gitignore")
      run_git!("-C", @project_root, "commit", "-m", "chore: ignore .hive-state worktree")
      :added
    end

    def commit_llm_wiki_bootstrap!
      paths = %w[
        .llm-wiki/config.json
        .llm-wiki/refresh-wiki.sh
        .llm-wiki/post-commit-refresh.sh
        .claude/settings.json
        AGENTS.md
        CLAUDE.md
        wiki/index.md
        wiki/log.md
        wiki/gaps.md
        wiki/architecture.md
        wiki/decisions.md
        wiki/dependencies.md
        raw/notes/.gitkeep
      ]
      existing = paths.select { |path| File.exist?(File.join(@project_root, path)) }
      return :nothing_to_commit if existing.empty?

      run_git!("-C", @project_root, "add", "--", *existing)
      _, _, status = Open3.capture3("git", "-C", @project_root, "diff", "--cached", "--quiet")
      return :nothing_to_commit if status.success?

      run_git!("-C", @project_root, "commit", "-m", "chore: initialize llm-wiki")
      :committed
    end

    # Scoped add: only stage files under stages/<stage_name>/<slug>/ and the
    # logs/ directory so a crashed prior run's leftover staging cannot cross-
    # contaminate this commit's message.
    def hive_commit(stage_name:, slug:, action:)
      message = "hive: #{stage_name}/#{slug} #{action}"
      task_path = File.join("stages", stage_name, slug)
      run_git!("-C", hive_state_path, "add", task_path) if File.directory?(File.join(hive_state_path, task_path))
      run_git!("-C", hive_state_path, "add", "logs") if File.directory?(File.join(hive_state_path, "logs"))
      _, _, status = Open3.capture3("git", "-C", hive_state_path, "diff", "--cached", "--quiet")
      if status.success?
        :nothing_to_commit
      else
        run_git!("-C", hive_state_path, "commit", "-m", message)
        :committed
      end
    end

    def detect_default_branch
      origin = origin_default_branch
      return origin if origin

      out, _err, status = Open3.capture3("git", "-C", @project_root,
                                         "rev-parse", "--abbrev-ref", "HEAD")
      return out.strip if status.success? && !out.strip.empty? && out.strip != "HEAD"

      out, _err, = Open3.capture3("git", "config", "init.defaultBranch")
      branch = out.strip
      return branch unless branch.empty?

      "master"
    end

    # Returns the project default branch when it can be derived from a
    # trusted remote source: either the origin/HEAD symref, or a probe
    # for the conventional origin/main / origin/master remote-tracking
    # refs. Returns nil when neither is available — callers that must
    # not fall back to the worktree's current branch (e.g. reviewer
    # compare ref resolution) check the nil and fail preflight instead.
    #
    # Both probes use the full `refs/remotes/origin/<branch>` path so a
    # tag named `origin/main` cannot satisfy the check (rev-parse
    # short-form `origin/main` is ambiguous with `refs/tags/origin/main`).
    def origin_default_branch
      out, _err, status = Open3.capture3("git", "-C", @project_root,
                                         "symbolic-ref", "refs/remotes/origin/HEAD")
      return out.strip.sub(%r{\Arefs/remotes/origin/}, "") if status.success? && !out.strip.empty?

      %w[main master].each do |candidate|
        return candidate if ref_exists?("refs/remotes/origin/#{candidate}")
      end

      nil
    end

    def run_git!(*args)
      out, err, status = Open3.capture3("git", *args)
      raise GitError, "git #{args.join(' ')} failed: #{err.strip.empty? ? out : err}" unless status.success?

      out
    end

    def run_git_quiet(*args)
      Open3.capture3("git", *args)
    end

    # ---- Rebase plumbing (for Hive::Rebase orchestrator) -------------

    # Returns the integer count of commits in `ref` that are NOT in the
    # current branch (HEAD). `commits_behind("origin/main") == 3` means
    # main has 3 commits HEAD hasn't seen yet. Returns 0 when ref is
    # unknown to git (caller handles the no-ref-no-rebase case via the
    # fetch step's success signal).
    def commits_behind(ref)
      out, _err, status = Open3.capture3("git", "-C", @project_root,
                                         "rev-list", "--count", "HEAD..#{ref}")
      return 0 unless status.success?

      Integer(out.strip, 10)
    rescue ArgumentError
      0
    end

    # `git fetch origin <ref>` with non-interactive env + a wall-clock
    # timeout (default 60s) so HTTPS network hangs don't block the
    # `Hive::Lock.with_task_lock` window. SSH credential / host-key
    # prompts are blocked by BatchMode + GIT_TERMINAL_PROMPT=0; the
    # process-level timeout catches the remaining network-stall
    # failure modes. Returns true on success, false on ANY failure
    # (network, auth prompt, timeout, unknown ref). NEVER raises —
    # the fail-soft path in Hive::Rebase treats false as "skip rebase".
    FETCH_TIMEOUT_SEC = 60
    def fetch_default_branch(ref, timeout_sec: FETCH_TIMEOUT_SEC)
      env = {
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_SSH_COMMAND"     => "ssh -oBatchMode=yes -oConnectTimeout=10"
      }
      pid = Process.spawn(env, "git", "-C", @project_root, "fetch", "origin", ref,
                          in: :close, out: "/dev/null", err: "/dev/null")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec
      loop do
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        return status.success? if status
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          Process.kill("TERM", pid)
          sleep 0.5
          begin
            Process.kill("KILL", pid)
          rescue Errno::ESRCH
            # already gone
          end
          Process.waitpid(pid)
          return false
        end
        sleep 0.1
      end
    rescue StandardError
      false
    end

    # True when `git status --porcelain` returns any output. Unmerged
    # (UU/AA/DU) files count as dirty too — rebase-in-progress states
    # would also trip this, but `rebase_in_progress?` should be checked
    # FIRST so its more-specific signal wins.
    def dirty?
      !status_short.strip.empty?
    end

    # True when HEAD is detached (no symbolic ref). Rebase against a
    # detached HEAD would discard the worktree's commits; refuse instead.
    def detached_head?
      _out, _err, status = Open3.capture3("git", "-C", @project_root,
                                          "symbolic-ref", "-q", "HEAD")
      !status.success?
    end

    # True when a rebase is mid-flight. Git records this state on disk
    # in either `.git/rebase-merge/` (interactive / default rebase) or
    # `.git/rebase-apply/` (legacy apply-based rebase). Either being
    # present is the canonical "rebase in progress" indicator.
    def rebase_in_progress?
      git_dir = run_git!("-C", @project_root, "rev-parse", "--git-dir").strip
      git_dir = File.expand_path(git_dir, @project_root)
      File.directory?(File.join(git_dir, "rebase-merge")) ||
        File.directory?(File.join(git_dir, "rebase-apply"))
    rescue GitError
      false
    end

    # Returns the array of unmerged (conflicting) paths from a rebase
    # mid-flight, relative to the project root. Empty when no rebase is
    # in progress or all conflicts are resolved + staged.
    def staged_unmerged_files
      out, _err, status = Open3.capture3("git", "-C", @project_root,
                                         "diff", "--name-only", "--diff-filter=U")
      return [] unless status.success?

      out.split("\n").map(&:strip).reject(&:empty?)
    end

    # Wall-clock budget for `git rebase` / `git rebase --continue`
    # operations. Hooks (pre-commit, post-rewrite, post-commit) can
    # stall for arbitrary time; the orchestrator's task-lock is
    # held during the whole rebase, so without a cap a slow hook
    # could block concurrent invocations for hours. PR #69 review
    # reliability #4.
    REBASE_OP_TIMEOUT_SEC = 300

    # Stdout/stderr cap for captured git operations to prevent
    # unbounded memory growth from a runaway hook or pathological
    # rebase. 1 MiB is generous for git's typical output (usually
    # <10 KiB). PR #69 review reliability #11.
    GIT_CAPTURE_MAX_BYTES = 1 << 20

    # `git rebase <ref>`. Returns true on clean rebase (fast-forward or
    # successful replay with no conflicts). Raises Hive::RebaseConflict
    # if git exits non-zero AND a rebase is mid-flight on disk (the
    # canonical conflict signal). Raises GitError for any other
    # non-zero exit (invalid ref, hook failure, etc.) including
    # timeout.
    def rebase_onto(ref)
      success, err, timed_out = run_git_with_timeout([ "git", "-C", @project_root, "rebase", ref ])
      return true if success

      if rebase_in_progress?
        raise RebaseConflict, "git rebase #{ref} halted with conflicts"
      end

      detail = if timed_out
        "timed out after #{REBASE_OP_TIMEOUT_SEC}s (hook stall?)"
      elsif err.strip.empty?
        "(no stderr)"
      else
        err.strip
      end
      raise GitError, "git rebase #{ref} failed: #{detail}"
    end

    # `git rebase --continue`. Returns true on clean continue (rebase
    # advances or completes). Raises RebaseConflict if more conflicts
    # surface on the next commit. Raises GitError otherwise (including
    # timeout).
    def rebase_continue
      env = { "GIT_EDITOR" => "true" }  # accept default commit message; never open an editor
      success, err, timed_out = run_git_with_timeout(
        [ "git", "-C", @project_root, "rebase", "--continue" ],
        env: env
      )
      return true if success

      if rebase_in_progress?
        raise RebaseConflict, "git rebase --continue halted with conflicts"
      end

      detail = if timed_out
        "timed out after #{REBASE_OP_TIMEOUT_SEC}s (hook stall?)"
      elsif err.strip.empty?
        "(no stderr)"
      else
        err.strip
      end
      raise GitError, "git rebase --continue failed: #{detail}"
    end

    # Run a git command with a wall-clock timeout (`REBASE_OP_TIMEOUT_SEC`)
    # and a stdout/stderr byte cap (`GIT_CAPTURE_MAX_BYTES`). Returns
    # `[success_bool, stderr_string, timed_out_bool]`. On timeout:
    # SIGTERM → 0.5s grace → SIGKILL → reap. Excess output beyond the
    # cap is dropped (the typical git op produces <10 KiB so this is
    # only relevant for runaway hooks).
    def run_git_with_timeout(cmd, env: {}, timeout_sec: REBASE_OP_TIMEOUT_SEC,
                             max_bytes: GIT_CAPTURE_MAX_BYTES)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      pid = Process.spawn(env, *cmd, in: :close, out: out_w, err: err_w)
      out_w.close
      err_w.close

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec
      out_buf = +""
      err_buf = +""
      readers = [ out_r, err_r ]
      timed_out = false

      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0
          timed_out = true
          break
        end
        ready, = IO.select(readers, [], [], [ remaining, 0.1 ].min)
        (ready || []).each do |r|
          begin
            chunk = r.read_nonblock(4096)
            if r == out_r && out_buf.bytesize < max_bytes
              out_buf << chunk[0, max_bytes - out_buf.bytesize]
            elsif r == err_r && err_buf.bytesize < max_bytes
              err_buf << chunk[0, max_bytes - err_buf.bytesize]
            end
          rescue IO::WaitReadable
            # spurious wakeup; loop
          rescue EOFError
            readers.delete(r)
            r.close
          end
        end
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        next unless status

        # Drain remaining bytes from the pipes before returning.
        readers.each do |r|
          begin
            loop do
              chunk = r.read_nonblock(4096)
              if r == out_r && out_buf.bytesize < max_bytes
                out_buf << chunk[0, max_bytes - out_buf.bytesize]
              elsif r == err_r && err_buf.bytesize < max_bytes
                err_buf << chunk[0, max_bytes - err_buf.bytesize]
              end
            end
          rescue IO::WaitReadable, EOFError
            # done draining
          end
          r.close unless r.closed?
        end
        return [ status.success?, err_buf, false ]
      end

      # Timeout path: SIGTERM, brief grace, SIGKILL.
      begin
        Process.kill("TERM", pid)
        sleep 0.5
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        # already gone
      end
      Process.waitpid(pid)
      [ out_r, err_r ].each { |r| r.close unless r.closed? }
      [ false, err_buf, true ]
    rescue StandardError => e
      [ false, e.message, false ]
    end

    # `git rebase --abort`. Returns true on success, false on failure
    # (rare — typically only if no rebase was in progress). Never
    # raises — abort is a recovery path and the caller has already
    # decided to give up.
    def rebase_abort
      _out, _err, status = Open3.capture3("git", "-C", @project_root, "rebase", "--abort")
      status.success?
    rescue StandardError
      false
    end

    # `git reset --hard ORIG_HEAD` followed by `git clean -fd`.
    # Used after `rebase_abort` to restore tracked files AND clean
    # any agent-created untracked files. `--hard` alone does NOT
    # remove untracked files (this was a wiki/plan misconception
    # caught in PR #69 review); `git clean -fd` is the actual
    # primitive for that. ORIG_HEAD is set by git at the start of
    # every rebase and points at the pre-rebase HEAD. Returns true
    # only when both operations succeed.
    def reset_hard_orig_head
      _out, _err, reset_status = Open3.capture3("git", "-C", @project_root,
                                                "reset", "--hard", "ORIG_HEAD")
      return false unless reset_status.success?

      _out, _err, clean_status = Open3.capture3("git", "-C", @project_root,
                                                "clean", "-fd")
      clean_status.success?
    rescue StandardError
      false
    end

    # Path to the in-flight rebase's commit message file. Honors
    # linked worktrees correctly: `<worktree>/.git` may be a regular
    # file containing `gitdir: <path>`, so we resolve via
    # `git rev-parse --git-dir` rather than hardcoding `.git/`.
    # Returns the path string when a rebase is in progress, nil
    # otherwise. Never raises — best-effort lookup for prompt
    # rendering.
    def rebase_merge_message_path
      git_dir = run_git!("-C", @project_root, "rev-parse", "--git-dir").strip
      git_dir = File.expand_path(git_dir, @project_root)
      candidate = File.join(git_dir, "rebase-merge", "message")
      return candidate if File.file?(candidate)

      apply_msg = File.join(git_dir, "rebase-apply", "msg-clean")
      return apply_msg if File.file?(apply_msg)

      nil
    rescue StandardError
      nil
    end
  end
end
