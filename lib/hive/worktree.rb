require "open3"
require "fileutils"
require "yaml"
require "hive/config"

module Hive
  class Worktree
    NONINTERACTIVE_FETCH_ENV = {
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_SSH_COMMAND" => "ssh -oBatchMode=yes -oConnectTimeout=10"
    }.freeze

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
      template = cfg["worktree_root"] ||
                 self.class.default_worktree_root(File.basename(@project_root))
      File.expand_path(template)
    end

    def exists?
      return false unless File.directory?(path)

      list_worktree_paths.include?(path)
    end

    def create!(branch_name, default_branch:, base_override: nil)
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
        base = if base_override.to_s.strip.empty?
                 freshest_base(default_branch)
               else
                 freshest_override_base(base_override, default_branch)
               end
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

    # Fallback used by drop when `git worktree remove` refuses (locked,
    # dirty tree, missing index). `--force` will discard uncommitted
    # work in the worktree, so callers must already have decided the
    # data is forfeit (drop is irreversible by contract).
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
      return default_branch unless self.class.origin_configured?(@project_root)

      _, err, status = self.class.fetch_origin_branch(@project_root, default_branch)
      unless status.success?
        warn "[hive] worktree base: fetch origin #{default_branch} failed " \
             "(#{err.strip[0, 200]}); branching from local #{default_branch}"
        return default_branch
      end

      "origin/#{default_branch}"
    end

    def freshest_override_base(base_override, default_branch)
      branch = base_override.to_s.strip
      return freshest_base(default_branch) if branch.empty?
      return freshest_base(default_branch) unless self.class.origin_configured?(@project_root)

      _, err, status = self.class.fetch_origin_branch(@project_root, branch)
      unless status.success?
        warn "[hive] worktree base: fetch origin #{branch} failed " \
             "(#{err.strip[0, 200]}); branching from #{default_branch}"
        return freshest_base(default_branch)
      end

      unless self.class.origin_branch_ref_exists?(@project_root, branch)
        warn "[hive] worktree base: origin/#{branch} not found after fetch; branching from #{default_branch}"
        return freshest_base(default_branch)
      end

      "origin/#{branch}"
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

      data = begin
        YAML.safe_load(File.read(pointer))
      rescue Psych::Exception, SystemCallError, IOError
        nil
      end
      return nil if data.nil?

      raise WorktreeError, "worktree.yml must be a hash" unless data.is_a?(Hash)

      data
    end

    # Base dir under which per-project worktree roots live by default
    # (`<base>/<project>.worktrees`). Overridable via HIVE_WORKTREE_BASE so
    # tests (and relocated setups) never seed the developer's real ~/Dev.
    def self.worktree_base
      ENV["HIVE_WORKTREE_BASE"] || File.expand_path("~/Dev")
    end

    def self.default_worktree_root(project_name)
      File.join(worktree_base, "#{project_name}.worktrees")
    end

    # Resolves the canonical worktree root for a project (per-project
    # `worktree_root` override, falling back to `<HIVE_WORKTREE_BASE or
    # ~/Dev>/<repo>.worktrees`). Shared by Drop and other callers so the
    # resolution rule has one home; previously Drop duplicated the formula
    # and would have silently drifted on any future change here.
    def self.canonical_root(project_root)
      cfg = Hive::Config.load(project_root)
      File.expand_path(
        cfg["worktree_root"] ||
          default_worktree_root(File.basename(File.expand_path(project_root)))
      )
    end

    def self.origin_branch_exists?(project_root, branch_name)
      branch = branch_name.to_s.strip
      return false if branch.empty?
      return false unless origin_configured?(project_root)

      _, _, status = fetch_origin_branch(project_root, branch)
      return false unless status.success?

      origin_branch_ref_exists?(project_root, branch)
    end

    def self.origin_configured?(project_root)
      _, _, has_origin = Open3.capture3("git", "-C", project_root,
                                        "config", "remote.origin.url")
      has_origin.success?
    end

    def self.fetch_origin_branch(project_root, branch_name)
      Open3.capture3(NONINTERACTIVE_FETCH_ENV, "git", "-C", project_root,
                     "fetch", "origin", branch_name)
    end

    def self.origin_branch_ref_exists?(project_root, branch_name)
      _, _, status = Open3.capture3("git", "-C", project_root,
                                    "rev-parse", "--verify", "--quiet",
                                    "refs/remotes/origin/#{branch_name}")
      status.success?
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
