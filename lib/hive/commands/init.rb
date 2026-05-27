require "open3"
require "fileutils"
require "stringio"
require "hive/config"
require "hive/git_ops"
require "hive/llm_wiki_bootstrap"
require "hive/commands/init/prompts"
require "hive/commands/doctor"
require "hive/commands/daemon/service_installer"
require "hive/invoked_binary"

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
        project_config_content = render_project_config(ops, answers: answers)

        ops.hive_state_init
        write_per_project_config(ops, content: project_config_content)
        ops.add_hive_state_to_master_gitignore!
        Hive::LlmWikiBootstrap.install!(@project_path, post_commit_hook: false, scheduler: false)
        ops.commit_llm_wiki_bootstrap!
        Hive::LlmWikiBootstrap.install_runtime_hooks!(@project_path)

        entry = Hive::Config.register_project(name: File.basename(@project_path), path: @project_path)

        print_summary(entry: entry, ops: ops)
        register_daemon_service!(autostart: true)
        run_init_preflight!
      end

      # Non-fatal skill preflight: after init succeeds, run the doctor
      # against the freshly-written config and emit stderr warnings for
      # any `:missing` rows. Init's exit code is unaffected — install
      # gaps surface but never block bootstrap.
      #
      # Rescue scope: `StandardError` for verifier bugs (with a
      # bug-report hint in the warning so silent swallow is mitigated).
      # `Errno::EPIPE` rescued narrowly around `warn` so a
      # `hive init | head` pattern doesn't crash. `Interrupt` and
      # `SystemExit` propagate (Ctrl-C honored as user intent).
      def run_init_preflight!
        cfg = Hive::Config.load(@project_path)
        doctor = Hive::Commands::Doctor.new(
          config: cfg,
          project_root: @project_path,
          output: StringIO.new
        )
        exit_code = doctor.call
        if exit_code == Hive::Commands::Doctor::EXIT_CONFIG_ERROR
          # Doctor caught a config issue internally; @rows is nil. Surface a
          # pointer rather than going silent.
          write_warn("hive: doctor pre-flight — config issue detected; run `hive doctor` for details")
          return
        end

        missing = Array(doctor.rows).select { |r| r[:status] == "missing" }
        return if missing.empty?

        emit_preflight_warnings(missing)
      rescue StandardError => e
        emit_preflight_bug(e)
      end

      def emit_preflight_warnings(missing)
        write_warn("hive: doctor pre-flight — found #{missing.size} issue(s):")
        missing.each do |r|
          write_warn("  [#{r[:label]}/#{r[:agent]}] #{r[:message]}")
        end
        write_warn("  See `hive doctor` for details.")
      end

      def emit_preflight_bug(error)
        write_warn(
          "hive: doctor pre-flight failed: #{error.class}: #{error.message} " \
          "(this may be a hive bug, please report at " \
          "https://github.com/ivankuznetsov/hive/issues)"
        )
      end

      def write_warn(line)
        warn line
      rescue Errno::EPIPE
        nil
      end

      def register_daemon_service!(autostart:)
        record_daemon_autostart!(autostart)
        installer = Hive::Commands::Daemon::ServiceInstaller.new(binary_path: current_binary_path)
        result = installer.install!(autostart: autostart)
        installer.messages.each { |line| write_warn("hive: #{line}") }
        if result == :failed
          write_warn("hive: daemon service registration reported a failure; run `hive doctor` and check daemon logs")
        end
      rescue Errno::EACCES, Errno::ENOSPC, Errno::EPERM => e
        write_warn("hive: daemon service registration failed (#{e.class}: #{e.message}); fix permissions and re-run `hive init`")
      rescue Hive::Error => e
        write_warn("hive: daemon service registration failed: #{e.message}")
      rescue StandardError => e
        # Daemon registration is best-effort and runs AFTER init has
        # already committed the hive/state branch, registered the
        # project, and printed the success summary. An unexpected error
        # here (a SystemCallError we did not list above, or a bug in
        # ServiceInstaller) must not abort a completed init with a stack
        # trace — degrade to a warning with a bug-report hint, mirroring
        # run_init_preflight!.
        write_warn(
          "hive: daemon service registration failed: #{e.class}: #{e.message} " \
          "(this may be a hive bug, please report at " \
          "https://github.com/ivankuznetsov/hive/issues)"
        )
      end

      def record_daemon_autostart!(autostart)
        Hive::Config.update_global_config! do |data|
          data["daemon"] = {} unless data["daemon"].is_a?(Hash)
          data["daemon"]["autostart"] = autostart ? true : false
        end
      end

      def current_binary_path
        Hive::InvokedBinary.path
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

      def write_per_project_config(ops, content:)
        cfg_path = File.join(ops.hive_state_path, "config.yml")
        return if File.exist?(cfg_path)

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
      # Hive::Commands::Init::Prompts (planning_agent / claude_mode /
      # development_agent / enabled_reviewers / triage_bias / budgets /
      # timeouts / daemon_enabled). The single source
      # of truth for the answers hash is `Prompts#collect`; this binding
      # never invents defaults of its own — callers always supply
      # `answers:` (production: from Prompts; tests: explicit hashes).
      # Budget and timeout sections are also validated against the full
      # prompt LIMIT_KEYS set so nested prompt/template drift fails fast.
      class ProjectConfigBinding
        def initialize(project_name:, default_branch:, worktree_root:, answers:)
          @project_name = project_name
          @default_branch = default_branch
          @worktree_root = worktree_root
          @planning_agent = answers.fetch("planning_agent")
          @claude_mode = answers.fetch("claude_mode")
          @development_agent = answers.fetch("development_agent")
          @enabled_reviewers = answers.fetch("enabled_reviewers")
          @triage_bias = answers.fetch("triage_bias")
          @budgets = required_limit_answers(answers.fetch("budgets"), "budgets")
          @timeouts = required_limit_answers(answers.fetch("timeouts"), "timeouts")
          @daemon_enabled = answers.fetch("daemon_enabled")
        end

        attr_reader :project_name, :default_branch, :worktree_root,
                    :planning_agent, :claude_mode, :development_agent,
                    :enabled_reviewers, :triage_bias, :budgets, :timeouts,
                    :daemon_enabled

        def binding_for_erb
          binding
        end

        def required_limit_answers(values, section)
          unless values.respond_to?(:fetch)
            raise KeyError, "key not found: #{section}"
          end

          Hive::Commands::Init::Prompts::LIMIT_KEYS.each_with_object({}) do |key, required|
            required[key] = values.fetch(key)
          end
        end
      end
    end
  end
end
