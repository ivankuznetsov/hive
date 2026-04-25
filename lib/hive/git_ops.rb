require "open3"
require "fileutils"

module Hive
  class GitOps
    HIVE_BRANCH = "hive/state".freeze
    STAGE_DIRS = %w[1-inbox 2-brainstorm 3-plan 4-execute 5-pr 6-done].freeze

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

      run_git!("-C", @project_root, "worktree", "add", "--no-checkout", "--detach",
               hive_state_path, default_branch)
      run_git!("-C", hive_state_path, "checkout", "--orphan", HIVE_BRANCH)
      run_git_quiet("-C", hive_state_path, "rm", "-rf", ".")
      FileUtils.rm_rf(Dir.glob(File.join(hive_state_path, "*")))
      FileUtils.rm_rf(Dir.glob(File.join(hive_state_path, ".[!.]*")).reject { |p| File.basename(p) == ".git" })

      STAGE_DIRS.each do |stage|
        d = File.join(hive_state_path, "stages", stage)
        FileUtils.mkdir_p(d)
        File.write(File.join(d, ".gitkeep"), "")
      end
      logs_dir = File.join(hive_state_path, "logs")
      FileUtils.mkdir_p(logs_dir)
      File.write(File.join(logs_dir, ".gitkeep"), "")

      run_git!("-C", hive_state_path, "add", ".")
      run_git!("-C", hive_state_path, "commit", "-m", "hive: bootstrap")
      :created
    end

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

    def hive_commit(stage_name:, slug:, action:)
      message = "hive: #{stage_name}/#{slug} #{action}"
      run_git!("-C", hive_state_path, "add", ".")
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
