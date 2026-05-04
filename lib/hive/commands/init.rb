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
          raise Hive::AlreadyInitialized,
                "already initialized; hive/state branch present at #{@project_path}"
        end

        ops.hive_state_init
        write_per_project_config(ops)
        ops.add_hive_state_to_master_gitignore!

        entry = Hive::Config.register_project(name: File.basename(@project_path), path: @project_path)

        print_summary(entry: entry, ops: ops)
      end

      def print_summary(entry:, ops:)
        c = Palette.for($stdout)
        name = entry["name"]
        rows = [
          [ "project",        @project_path ],
          [ "default branch", ops.default_branch ],
          [ "hive state",     ops.hive_state_path ],
          [ "worktree root",  worktree_root ]
        ]
        label_width = rows.map { |k, _| k.length }.max

        $stdout.puts "#{c.green('✔')} #{c.bold('hive: initialized')} #{c.bold_cyan(name)}"
        rows.each do |label, value|
          $stdout.puts "  #{c.dim(label.ljust(label_width))}  #{value}"
        end
        $stdout.puts
        $stdout.puts "#{c.cyan('→')} #{c.bold('next:')} hive new #{name} '<short task description>'"
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

      # Minimal ANSI palette for one-shot CLI summaries. Honors
      # NO_COLOR and falls back to plain text on non-tty IO so piped
      # callers (CI, `hive init … | tee …`) get clean output.
      class Palette
        CODES = {
          reset: "\e[0m",
          bold: "\e[1m",
          dim: "\e[2m",
          green: "\e[32m",
          cyan: "\e[36m",
          bold_cyan: "\e[1;36m"
        }.freeze

        def self.for(io)
          color = io.respond_to?(:tty?) && io.tty? && (ENV["NO_COLOR"].nil? || ENV["NO_COLOR"].empty?)
          new(color: color)
        end

        def initialize(color:)
          @color = color
        end

        CODES.each_key do |name|
          next if name == :reset

          define_method(name) do |text|
            @color ? "#{CODES[name]}#{text}#{CODES[:reset]}" : text.to_s
          end
        end
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
