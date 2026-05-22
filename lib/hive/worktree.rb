require "open3"
require "fileutils"
require "yaml"

module Hive
  class Worktree
    attr_reader :project_root, :slug

    def initialize(project_root, slug, worktree_root: nil)
      @project_root = File.expand_path(project_root)
      @slug = slug
      @worktree_root = worktree_root && File.expand_path(worktree_root)
    end

    def path
      File.join(worktree_root, @slug)
    end

    def worktree_root
      return @worktree_root if @worktree_root

      cfg = Hive::Config.load(@project_root)
      template = cfg["worktree_root"] || File.expand_path("~/Dev/#{File.basename(@project_root)}.worktrees")
      File.expand_path(template)
    end

    def exists?
      return false unless File.directory?(path)

      list_worktree_paths.include?(path)
    end

    def create!(branch_name, default_branch:)
      FileUtils.mkdir_p(File.dirname(path))

      _, _, exists = Open3.capture3("git", "-C", @project_root,
                                    "show-ref", "--verify", "refs/heads/#{branch_name}")
      if exists.success?
        args = [ "worktree", "add", path, branch_name ]
      else
        # Branch new worktrees from `origin/<default>` (after a quick
        # fetch) instead of local `<default>` so a stale or
        # behind-origin local default doesn't silently produce a
        # worktree missing the latest upstream commits. Auto-rebase
        # (PR #69) handles drift in long-running worktrees; this
        # handles drift at creation time. Fail-soft: if there is no
        # `origin` remote, or the fetch fails (network down, auth),
        # fall back to the local default with a stderr warning.
        # Never touches local `<default>` — preserves any unpushed
        # commits the user has there.
        base = freshest_base(default_branch)
        args = [ "worktree", "add", path, "-b", branch_name, base ]
      end
      out, err, status = Open3.capture3("git", "-C", @project_root, *args)
      unless status.success?
        raise WorktreeError, "git worktree add failed: #{err.strip.empty? ? out : err}"
      end

      :created
    end

    def remove!(path: self.path, force: false)
      args = [ "worktree", "remove" ]
      args << "--force" if force
      args << path
      out, err, status = Open3.capture3("git", "-C", @project_root, *args)
      raise WorktreeError, "git worktree remove failed: #{err.strip.empty? ? out : err}" unless status.success?

      :removed
    end

    def remove_force!(path: self.path)
      remove!(path: path, force: true)
    end

    # Decide what to base a new worktree branch on. Prefer
    # `origin/<default>` after a quick fetch so the worktree starts
    # at upstream's current tip. Fall back to local `<default>` on:
    #   - no `origin` remote configured (early-stage repos, forks
    #     without an upstream)
    #   - fetch failure (network down, auth missing, dead remote)
    # The fetch uses the same non-interactive env as
    # `GitOps#fetch_default_branch` (PR #69) so credential prompts
    # cannot hang the worktree-creation path.
    def freshest_base(default_branch)
      _, _, has_origin = Open3.capture3("git", "-C", @project_root,
                                        "config", "remote.origin.url")
      return default_branch unless has_origin.success?

      env = {
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_SSH_COMMAND" => "ssh -oBatchMode=yes -oConnectTimeout=10"
      }
      _, err, status = Open3.capture3(env, "git", "-C", @project_root,
                                      "fetch", "origin", default_branch)
      unless status.success?
        warn "[hive] worktree base: fetch origin #{default_branch} failed " \
             "(#{err.strip[0, 200]}); branching from local #{default_branch}"
        return default_branch
      end

      "origin/#{default_branch}"
    end

    def list_worktree_paths
      out, _err, status = Open3.capture3("git", "-C", @project_root, "worktree", "list", "--porcelain")
      return [] unless status.success?

      out.split("\n").select { |l| l.start_with?("worktree ") }.map { |l| l.sub(/\Aworktree /, "").strip }
    end

    def write_pointer!(task_folder, branch_name, execute_base_head: nil)
      data = {
        "path" => path,
        "branch" => branch_name,
        "created_at" => Time.now.utc.iso8601
      }
      data["execute_base_head"] = execute_base_head if execute_base_head
      File.write(File.join(task_folder, "worktree.yml"), data.to_yaml)
    end

    def self.read_pointer(task_folder)
      pointer = File.join(task_folder, "worktree.yml")
      return nil unless File.exist?(pointer)

      data = YAML.safe_load(File.read(pointer)) || {}
      raise WorktreeError, "worktree.yml must be a hash" unless data.is_a?(Hash)

      data
    end

    # Resolve symlinks before the prefix check — File.expand_path normalises
    # `..` and `~` lexically but does not follow symlinks. An agent that
    # writes a symlink at the worktree path could otherwise escape the root.
    def self.validate_pointer_path(pointer_path, expected_root)
      expanded = realpath_or_expand(pointer_path)
      expected_prefix = realpath_or_expand(expected_root)
      unless expanded.start_with?(expected_prefix + File::SEPARATOR) || expanded == expected_prefix
        raise WorktreeError,
              "worktree path #{expanded} is outside expected root #{expected_prefix}"
      end

      expanded
    end

    def self.realpath_or_expand(path)
      File.realpath(path)
    rescue Errno::ENOENT
      # Path doesn't exist yet (init pass before mkdir); fall back to lexical.
      File.expand_path(path)
    end
  end
end
