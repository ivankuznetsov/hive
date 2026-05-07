require "open3"
require "fileutils"
require "hive/config"
require "hive/git_ops"
require "hive/commands/init/prompts"

module Hive
  module Commands
    class Init
      def initialize(project_path, force: false, prompts: nil)
        @project_path = File.expand_path(project_path)
        @force = force
        # Optional Prompts instance for testability. Tests inject a
        # pre-fed StringIO-backed instance to drive the interactive flow
        # without touching $stdin. Production keeps this nil so the
        # default `Prompts.new(input: $stdin, output: $stderr,
        # summary_io: $stdout)` runs (UI on stderr, machine-parseable
        # summary on stdout — see #collect_prompt_answers below).
        @prompts = prompts
      end

      def call
        validate_git_repo!
        validate_clean_tree! unless @force

        ops = Hive::GitOps.new(@project_path)
        if ops.hive_state_branch_exists?
          raise Hive::AlreadyInitialized,
                "already initialized; hive/state branch present at #{@project_path}"
        end

        # Prompt placement is load-bearing (per ADR-023): runs AFTER the
        # already-initialized guard above, BEFORE any disk writes below.
        # An aborted prompt (`n` at confirmation) leaves zero footprint —
        # no orphan branch, no worktree, no master .gitignore update —
        # so a re-run of `hive init` proceeds normally.
        answers = collect_prompt_answers

        ops.hive_state_init
        write_per_project_config(ops, answers: answers)
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

      def collect_prompt_answers
        prompts = @prompts || Hive::Commands::Init::Prompts.new(input: $stdin, output: $stderr, summary_io: $stdout)
        prompts.collect
      rescue Hive::Commands::Init::Prompts::Aborted => e
        # Distinct exit code (USAGE / 64) from generic crashes (GENERIC / 1)
        # so a scripted agent can tell "user explicitly declined" from
        # "init crashed transiently" and decide whether to retry. Closes
        # ce-code-review F6.
        warn "hive: aborted (#{e.message}); no changes made"
        exit Hive::ExitCodes::USAGE
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

      def write_per_project_config(ops, answers:)
        cfg_path = File.join(ops.hive_state_path, "config.yml")
        return if File.exist?(cfg_path)

        content = render_project_config(ops, answers: answers)
        File.write(cfg_path, content)
      end

      def render_project_config(ops, answers:)
        require "erb"
        template = File.read(File.expand_path("../../../templates/project_config.yml.erb", __dir__))
        bindings = ProjectConfigBinding.new(
          project_name: File.basename(@project_path),
          default_branch: ops.default_branch,
          worktree_root: worktree_root,
          answers: answers
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

      # ERB binding object for templates/project_config.yml.erb. Carries
      # the per-project scaffolding values (project name, default branch,
      # worktree root) plus the prompted answers hash from
      # Hive::Commands::Init::Prompts (planning_agent / development_agent /
      # enabled_reviewers / budgets / timeouts). The single source of
      # truth for the answers hash is `Prompts#collect`; this binding
      # never invents defaults of its own — callers always supply
      # `answers:` (production: from Prompts; tests: explicit hashes).
      class ProjectConfigBinding
        def initialize(project_name:, default_branch:, worktree_root:, answers:)
          @project_name = project_name
          @default_branch = default_branch
          @worktree_root = worktree_root
          @planning_agent = answers.fetch("planning_agent")
          @development_agent = answers.fetch("development_agent")
          @enabled_reviewers = answers.fetch("enabled_reviewers")
          @budgets = answers.fetch("budgets")
          @timeouts = answers.fetch("timeouts")
          # Default to true for legacy answer hashes that don't carry the
          # daemon key (e.g. integration fixtures predating ADR-024).
          # Production answers always set this explicitly via Prompts.
          @daemon_enabled = answers.fetch("daemon_enabled", true)
        end

        attr_reader :project_name, :default_branch, :worktree_root,
                    :planning_agent, :development_agent,
                    :enabled_reviewers, :budgets, :timeouts, :daemon_enabled

        def binding_for_erb
          binding
        end
      end
    end
  end
end
