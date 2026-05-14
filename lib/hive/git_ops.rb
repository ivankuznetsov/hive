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
      out, _err, status = Open3.capture3("git", "-C", @project_root,
                                         "symbolic-ref", "refs/remotes/origin/HEAD")
      return out.strip.sub(%r{\Arefs/remotes/origin/}, "") if status.success? && !out.strip.empty?

      out, _err, status = Open3.capture3("git", "-C", @project_root,
                                         "rev-parse", "--abbrev-ref", "HEAD")
      return out.strip if status.success? && !out.strip.empty? && out.strip != "HEAD"

      out, _err, = Open3.capture3("git", "config", "init.defaultBranch")
      branch = out.strip
      return branch unless branch.empty?

      "master"
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

    # `git fetch origin <ref>` with non-interactive env. Returns true on
    # success, false on ANY failure (network, auth prompt, unknown ref).
    # The fail-soft path in Hive::Rebase treats false as "skip rebase",
    # so this method must NEVER raise.
    def fetch_default_branch(ref)
      env = {
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_SSH_COMMAND"     => "ssh -oBatchMode=yes -oConnectTimeout=10"
      }
      _out, _err, status = Open3.capture3(env, "git", "-C", @project_root,
                                          "fetch", "origin", ref)
      status.success?
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

    # `git rebase <ref>`. Returns true on clean rebase (fast-forward or
    # successful replay with no conflicts). Raises Hive::RebaseConflict
    # if git exits non-zero AND a rebase is mid-flight on disk (the
    # canonical conflict signal). Raises GitError for any other
    # non-zero exit (invalid ref, hook failure, etc.).
    def rebase_onto(ref)
      _out, err, status = Open3.capture3("git", "-C", @project_root, "rebase", ref)
      return true if status.success?

      if rebase_in_progress?
        raise RebaseConflict, "git rebase #{ref} halted with conflicts"
      end

      raise GitError, "git rebase #{ref} failed: #{err.strip.empty? ? '(no stderr)' : err.strip}"
    end

    # `git rebase --continue`. Returns true on clean continue (rebase
    # advances or completes). Raises RebaseConflict if more conflicts
    # surface on the next commit. Raises GitError otherwise.
    def rebase_continue
      env = { "GIT_EDITOR" => "true" }  # accept default commit message; never open an editor
      _out, err, status = Open3.capture3(env, "git", "-C", @project_root, "rebase", "--continue")
      return true if status.success?

      if rebase_in_progress?
        raise RebaseConflict, "git rebase --continue halted with conflicts"
      end

      raise GitError, "git rebase --continue failed: #{err.strip.empty? ? '(no stderr)' : err.strip}"
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

    # `git reset --hard ORIG_HEAD`. Used after `rebase_abort` to clean
    # any agent-created untracked files (which `--abort` doesn't
    # remove). ORIG_HEAD is set by git at the start of every rebase
    # and points at the pre-rebase HEAD. Returns true on success.
    def reset_hard_orig_head
      _out, _err, status = Open3.capture3("git", "-C", @project_root,
                                          "reset", "--hard", "ORIG_HEAD")
      status.success?
    rescue StandardError
      false
    end
  end
end
