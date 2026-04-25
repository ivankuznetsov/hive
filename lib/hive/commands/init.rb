require "open3"
require "fileutils"
require "hive/config"
require "hive/git_ops"

module Hive
  module Commands
    class Init
      def initialize(project_path, force: false)
        @project_path = File.expand_path(project_path)
        @force = force
      end

      def call
        validate_git_repo!
        validate_clean_tree! unless @force

        ops = Hive::GitOps.new(@project_path)
        if ops.hive_state_branch_exists?
          warn "hive: already initialized; hive/state branch present at #{@project_path}"
          exit 2
        end

        ops.hive_state_init
        write_per_project_config(ops)
        ops.add_hive_state_to_master_gitignore!

        entry = Hive::Config.register_project(name: File.basename(@project_path), path: @project_path)

        puts "hive: initialized #{entry['name']} at #{@project_path}"
        puts "  default_branch: #{ops.default_branch}"
        puts "  hive_state_path: #{ops.hive_state_path}"
        puts "  worktree_root: #{worktree_root}"
        puts "next: hive new #{entry['name']} '<short task description>'"
      end

      def validate_git_repo!
        out, _err, status = Open3.capture3("git", "-C", @project_path, "rev-parse", "--git-common-dir")
        unless status.success?
          warn "hive: not a git repository: #{@project_path}"
          exit 1
        end

        common = File.expand_path(out.strip, @project_path)
        expected = File.join(@project_path, ".git")
        return if File.expand_path(common) == File.expand_path(expected)

        warn "hive: target appears to be inside a worktree (common dir #{common}); init must run on the main checkout"
        exit 1
      end

      def validate_clean_tree!
        out, _err, status = Open3.capture3("git", "-C", @project_path, "status", "--porcelain")
        raise GitError, "git status failed" unless status.success?

        # Only fail on tracked-modified or staged changes; untracked files (??)
        # don't interfere with init's gitignore commit.
        modified = out.lines.reject { |l| l.start_with?("??") }
        return if modified.empty?

        warn "hive: uncommitted modifications to tracked files; commit or pass --force"
        exit 1
      end

      def write_per_project_config(ops)
        cfg_path = File.join(ops.hive_state_path, "config.yml")
        return if File.exist?(cfg_path)

        content = render_project_config(ops)
        File.write(cfg_path, content)
      end

      def render_project_config(ops)
        require "erb"
        template = File.read(File.expand_path("../../../templates/project_config.yml.erb", __dir__))
        bindings = ProjectConfigBinding.new(
          project_name: File.basename(@project_path),
          default_branch: ops.default_branch,
          worktree_root: worktree_root
        )
        ERB.new(template, trim_mode: "-").result(bindings.binding_for_erb)
      end

      def worktree_root
        File.expand_path("~/Dev/#{File.basename(@project_path)}.worktrees")
      end

      class ProjectConfigBinding
        def initialize(project_name:, default_branch:, worktree_root:)
          @project_name = project_name
          @default_branch = default_branch
          @worktree_root = worktree_root
        end

        attr_reader :project_name, :default_branch, :worktree_root

        def binding_for_erb
          binding
        end
      end
    end
  end
end
