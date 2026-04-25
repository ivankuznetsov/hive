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
  end
end
