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
      args = if exists.success?
               [ "worktree", "add", path, branch_name ]
      else
               [ "worktree", "add", path, "-b", branch_name, default_branch ]
      end
      out, err, status = Open3.capture3("git", "-C", @project_root, *args)
      unless status.success?
        raise WorktreeError, "git worktree add failed: #{err.strip.empty? ? out : err}"
      end

      :created
    end

    def remove!
      out, err, status = Open3.capture3("git", "-C", @project_root, "worktree", "remove", path)
      raise WorktreeError, "git worktree remove failed: #{err.strip.empty? ? out : err}" unless status.success?

      :removed
    end

    def list_worktree_paths
      out, _err, status = Open3.capture3("git", "-C", @project_root, "worktree", "list", "--porcelain")
      return [] unless status.success?

      out.split("\n").select { |l| l.start_with?("worktree ") }.map { |l| l.sub(/\Aworktree /, "").strip }
    end

    def write_pointer!(task_folder, branch_name)
      data = {
        "path" => path,
        "branch" => branch_name,
        "created_at" => Time.now.utc.iso8601
      }
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
