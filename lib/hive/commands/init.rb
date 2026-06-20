require "open3"
require "fileutils"
require "json"
require "shellwords"
require "stringio"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/stages"
require "hive/task_meta"
require "hive/worktree"
require "hive/workflow_selection"
require "hive/llm_wiki_bootstrap"
require "hive/commands/init/prompts"
require "hive/commands/doctor"
require "hive/commands/daemon/service_installer"
require "hive/invoked_binary"

module Hive
  module Commands
    class Init
      INIT_MAIN_CHECKOUT_PATHS = %w[
        .gitignore
        .llm-wiki/config.json
        .llm-wiki/refresh-wiki.sh
        .llm-wiki/post-commit-refresh.sh
        .claude/settings.json
        AGENTS.md
        CLAUDE.md
        wiki/index.md
        wiki/log.md
        wiki/log.d/.gitkeep
        wiki/gaps.md
        wiki/architecture.md
        wiki/decisions.md
        wiki/dependencies.md
        raw/notes/.gitkeep
      ].freeze

      INIT_MAIN_CHECKOUT_DIRS = %w[
        .llm-wiki
        .claude
        wiki
        wiki/log.d
        raw
        raw/notes
      ].freeze

      WorkflowChoice = Struct.new(:descriptor, :source, keyword_init: true)

      def initialize(project_path, force: false, json: false, prompts: nil,
                     workflow: nil, workflow_input: $stdin, workflow_output: $stderr)
        @project_path = File.expand_path(project_path)
        @force = force
        @json = json
        @workflow_name = workflow
        @workflow_input = workflow_input
        @workflow_output = workflow_output
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
        workflow_choice = resolve_workflow_choice(ops)
        if ops.hive_state_branch_exists?
          if workflow_choice.source == :implicit
            raise Hive::AlreadyInitialized,
                  "already initialized; hive/state branch present at #{@project_path}"
          end
          handle_existing_project(ops, workflow_choice: workflow_choice)
          return
        end

        # Prompt placement is load-bearing (per ADR-023): runs AFTER the
        # already-initialized guard above, BEFORE any disk writes below.
        # An aborted prompt (`n` at confirmation) leaves zero footprint —
        # no orphan branch, no worktree, no master .gitignore update —
        # so a re-run of `hive init` proceeds normally.
        answers = collect_prompt_answers
        project_config_content = render_project_config(ops, answers: answers, default_workflow: workflow_choice.descriptor.id)
        entry = initialize_project_state(ops, content: project_config_content)

        if @json
          emit_json_summary(entry: entry, ops: ops, answers: answers)
        else
          print_summary(entry: entry, ops: ops, answers: answers)
        end
        register_daemon_service!(autostart: answers.fetch("daemon_autostart", false))
        run_init_preflight!
      rescue Hive::Commands::Init::Prompts::Aborted => e
        # The interactive WORKFLOW prompt (resolve_workflow_choice, which runs
        # before collect_prompt_answers) aborts on closed stdin. Mirror
        # collect_prompt_answers' contract: USAGE (64), not a generic
        # InternalError crash, and zero disk state (the prompt is BEFORE any
        # writes, per ADR-023).
        warn "hive: aborted (#{e.message}); no changes made"
        exit Hive::ExitCodes::USAGE
      rescue Hive::Error
        raise
      rescue StandardError => e
        raise Hive::InternalError, "init failed: #{e.class}: #{e.message}"
      end

      def handle_existing_project(ops, workflow_choice:)
        ops.ensure_hive_state_worktree_attached
        # `:implicit` re-init already raised AlreadyInitialized in `call` before
        # reaching here, so this path only sees :flag / :prompt — both express a
        # default-workflow intent and run the (idempotent) rebind.
        update_existing_default_workflow!(ops, workflow_choice.descriptor.id)
        Hive::Config.register_project(name: File.basename(@project_path), path: @project_path)
        if @json
          emit_existing_json_summary(ops, workflow_choice: workflow_choice)
        else
          write_existing_summary(ops, workflow_choice: workflow_choice)
        end
      end

      def write_existing_summary(_ops, workflow_choice:)
        $stdout.puts "hive: already initialized #{File.basename(@project_path)}"
        $stdout.puts "workflow: #{workflow_choice.descriptor.id}"
      rescue Errno::EPIPE
        nil
      end

      # An agent re-running `hive init --workflow X --json` on an existing
      # project would otherwise get exit 0 with EMPTY stdout — no confirmation
      # of the re-bind. Emit a minimal `already_initialized` hive-init payload
      # (a distinct oneOf arm from the fresh SuccessPayload in the schema).
      def emit_existing_json_summary(ops, workflow_choice:)
        puts JSON.generate(
          "schema" => "hive-init",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-init"),
          "ok" => true,
          "already_initialized" => true,
          "project" => File.basename(@project_path),
          "path" => @project_path,
          "hive_state_path" => ops.hive_state_path,
          "workflow" => workflow_choice.descriptor.id.to_s
        )
      rescue Errno::EPIPE
        nil
      end

      def update_existing_default_workflow!(ops, workflow_id)
        cfg_path = File.join(ops.hive_state_path, "config.yml")
        current = current_default_workflow(ops)
        next_value = workflow_id.to_s
        # Idempotent confirm (A8): re-running with the SAME default is a clean
        # no-op — no warning, no rewrite, no commit.
        return if current == next_value

        warn_on_fieldless_tasks_rebinding(ops, from: current, to: next_value)
        # Mutate config.yml atomically and COMMIT it under the per-project
        # commit lock, like every other hive/state mutation. A bare File.write
        # left the hive/state worktree permanently dirty (a later reset/clean
        # silently reverted the default) and an interrupted write could truncate
        # config.yml — masked by Config.load's Psych-rescue → coding fallback.
        Hive::Lock.with_commit_lock(ops.hive_state_path) do
          write_default_workflow!(cfg_path, next_value)
          ops.hive_commit(
            stage_name: "config",
            slug: "default_workflow",
            action: "set to #{next_value}",
            pathspecs: [ "config.yml" ]
          )
        end
      end

      def current_default_workflow(ops)
        cfg_path = File.join(ops.hive_state_path, "config.yml")
        return Hive::Config::DEFAULTS["default_workflow"] unless File.exist?(cfg_path)

        raw = YAML.safe_load(File.read(cfg_path)) || {}
        value = raw.is_a?(Hash) ? raw["default_workflow"].to_s.strip : ""
        value.empty? ? Hive::Config::DEFAULTS["default_workflow"] : value
      rescue Psych::Exception, SystemCallError => e
        # Don't silently assume coding on a corrupt config (unlike a clean
        # absent/blank value): the rebind warning would under-report and the
        # line-edit proceeds on an unparseable file. Surface it, mirroring
        # Task#load_project_default_workflow.
        write_warn("hive: could not read default_workflow from #{cfg_path} " \
                   "(#{e.class}: #{e.message}); assuming #{Hive::Config::DEFAULTS['default_workflow']}")
        Hive::Config::DEFAULTS["default_workflow"]
      end

      def write_default_workflow!(cfg_path, workflow_id)
        FileUtils.mkdir_p(File.dirname(cfg_path))
        content = File.exist?(cfg_path) ? File.read(cfg_path) : "---\n"
        lines = content.lines
        existing = lines.index { |line| line.match?(/\Adefault_workflow:/) }

        if Hive::Workflows.coding_id?(workflow_id)
          lines.delete_at(existing) if existing
        elsif existing
          lines[existing] = "default_workflow: #{workflow_id}\n"
        else
          lines.insert(default_workflow_insert_index(lines), "default_workflow: #{workflow_id}\n")
        end

        atomic_write(cfg_path, lines.join)
      end

      # Place the new `default_workflow:` line right after `hive_state_path:`
      # when present; otherwise after the leading `---` document marker (the
      # first non-marker line), or at the top of a degenerate marker-less file.
      # Only reachable on a hand-mangled config — the value is read correctly
      # wherever it lands.
      def default_workflow_insert_index(lines)
        after_state_path = lines.index { |line| line.match?(/\Ahive_state_path:/) }
        return after_state_path + 1 if after_state_path

        lines.index { |line| !line.start_with?("---") } || lines.length
      end

      # tmp + rename so an interrupted init can never leave a half-written
      # config.yml that Config.load's Psych-rescue would silently mask as the
      # coding default.
      def atomic_write(path, content)
        tmp = File.join(File.dirname(path), ".#{File.basename(path)}.tmp.#{Process.pid}")
        File.write(tmp, content)
        File.rename(tmp, path)
      ensure
        FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
      end

      def warn_on_fieldless_tasks_rebinding(ops, from:, to:)
        tasks = fieldless_in_flight_tasks(ops)
        return if tasks.empty?

        write_warn(
          "hive: changing default_workflow from #{from} to #{to} re-binds " \
          "#{tasks.size} in-flight task(s) with no meta.yml workflow: field. Any whose " \
          "current stage dir #{to} does not define will fail to load as Error rows and " \
          "stop advancing (Policy maps error → skip) — pin them with `workflow: #{from}` " \
          "in meta.yml first:"
        )
        tasks.first(5).each { |task| write_warn("  #{task}") }
        write_warn("  ... and #{tasks.size - 5} more") if tasks.size > 5
      end

      def fieldless_in_flight_tasks(ops)
        stages_root = File.join(ops.hive_state_path, "stages")
        terminal_dirs = Hive::Workflows::Registry.all.map { |workflow| workflow.stages.last.dir }.uniq
        Dir.glob(File.join(stages_root, "*", "*")).sort.filter_map do |path|
          next unless File.directory?(path)
          next unless Hive::Stages.task_slug?(File.basename(path))

          stage_dir = File.basename(File.dirname(path))
          next if terminal_dirs.include?(stage_dir)
          next if Hive::TaskMeta.read(path)[:workflow]

          File.join(stage_dir, File.basename(path))
        end
      end

      def initialize_project_state(ops, content:)
        rollback_on_failure = false
        side_effect_snapshot = capture_init_side_effect_snapshot
        begin
          rollback_on_failure = true
          init_result = ops.hive_state_init
          rollback_on_failure = init_result == :created
          write_per_project_config(ops, content: content)
          ops.add_hive_state_to_master_gitignore!
          Hive::LlmWikiBootstrap.install!(@project_path, post_commit_hook: false, scheduler: false)
          ops.commit_llm_wiki_bootstrap!
          Hive::LlmWikiBootstrap.install_runtime_hooks!(@project_path)

          Hive::Config.register_project(name: File.basename(@project_path), path: @project_path)
        rescue StandardError
          rollback_partial_init(ops, side_effect_snapshot: side_effect_snapshot) if rollback_on_failure
          raise
        end
      end

      def rollback_partial_init(ops, side_effect_snapshot: nil)
        results = []
        errors = []
        rollback_config_file(ops, results, errors)
        rollback_hive_state_worktree(ops, results, errors)
        rollback_hive_state_branch(ops, results, errors)
        rollback_init_side_effects(side_effect_snapshot, results, errors)
        report_partial_init_rollback(ops, results, errors)
      rescue StandardError => e
        write_warn("hive: partial init failed; rollback failed: #{e.class}: #{e.message}")
        write_warn("hive: recover with: #{partial_init_recovery_command(ops)}")
      end

      def rollback_config_file(ops, results, errors)
        path = File.join(ops.hive_state_path, "config.yml")
        return unless File.exist?(path)

        FileUtils.rm_f(path)
        results << "config.yml"
      rescue StandardError => e
        errors << "config.yml cleanup failed: #{e.class}: #{e.message}"
      end

      def rollback_hive_state_worktree(ops, results, errors)
        return unless File.exist?(ops.hive_state_path)

        out, err, status = Open3.capture3(
          "git", "-C", @project_path, "worktree", "remove", "--force", ops.hive_state_path
        )
        if status.success?
          results << ".hive-state worktree"
        else
          errors << rollback_error("git worktree remove", out, err)
        end
      end

      def rollback_hive_state_branch(ops, results, errors)
        return unless ops.hive_state_branch_exists?

        out, err, status = Open3.capture3("git", "-C", @project_path, "branch", "-D", Hive::GitOps::HIVE_BRANCH)
        if status.success?
          results << "hive/state branch"
        else
          errors << rollback_error("git branch -D", out, err)
        end
      end

      def capture_init_side_effect_snapshot
        {
          head: current_project_head,
          paths: init_side_effect_paths.to_h { |path| [ path, snapshot_path(path) ] }
        }
      end

      def init_side_effect_paths
        project_paths = (INIT_MAIN_CHECKOUT_PATHS + INIT_MAIN_CHECKOUT_DIRS).map do |path|
          File.join(@project_path, path)
        end
        project_paths + [
          File.join(@project_path, ".git", "hooks", "post-commit"),
          *llm_wiki_scheduler_paths,
          Hive::Config.global_config_path
        ]
      end

      def llm_wiki_scheduler_paths
        user_dir = File.expand_path("~/.config/systemd/user")
        slug = Hive::LlmWikiBootstrap.project_slug(@project_path)
        service = "llm-wiki-#{slug}.service"
        timer = "llm-wiki-#{slug}.timer"
        [
          File.join(user_dir, service),
          File.join(user_dir, timer),
          File.join(user_dir, "timers.target.wants", timer)
        ]
      end

      def snapshot_path(path)
        if File.symlink?(path)
          { type: :symlink, target: File.readlink(path), mode: File.lstat(path).mode & 0o7777 }
        elsif File.file?(path)
          { type: :file, content: File.binread(path), mode: File.stat(path).mode & 0o7777 }
        elsif File.directory?(path)
          { type: :directory, mode: File.stat(path).mode & 0o7777 }
        else
          { type: :absent }
        end
      end

      def current_project_head
        out, _err, status = Open3.capture3("git", "-C", @project_path, "rev-parse", "HEAD")
        status.success? ? out.strip : nil
      end

      def rollback_init_side_effects(snapshot, results, errors)
        return unless snapshot

        rollback_main_checkout_commits(snapshot, results, errors)
        rollback_main_checkout_index(errors)
        restore_init_side_effect_paths(snapshot.fetch(:paths), results, errors)
      end

      def rollback_main_checkout_commits(snapshot, results, errors)
        head = snapshot[:head]
        return if head.to_s.empty?

        current = current_project_head
        return if current == head

        out, err, status = Open3.capture3("git", "-C", @project_path, "reset", "--soft", head)
        if status.success?
          results << "main checkout commits"
        else
          errors << rollback_error("git reset --soft", out, err)
        end
      end

      def rollback_main_checkout_index(errors)
        out, err, status = Open3.capture3(
          "git", "-C", @project_path, "reset", "-q", "--", *INIT_MAIN_CHECKOUT_PATHS
        )
        errors << rollback_error("git reset init paths", out, err) unless status.success?
      end

      def restore_init_side_effect_paths(paths, results, errors)
        changed = false
        paths.each do |path, snapshot|
          changed = true if restore_init_side_effect_path(path, snapshot)
        rescue StandardError => e
          errors << "#{path} restore failed: #{e.class}: #{e.message}"
        end
        results << "main checkout side effects" if changed
      end

      def restore_init_side_effect_path(path, snapshot)
        case snapshot.fetch(:type)
        when :absent
          return false unless File.exist?(path) || File.symlink?(path)

          FileUtils.rm_rf(path)
          true
        when :file
          FileUtils.rm_rf(path) if File.directory?(path) && !File.symlink?(path)
          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, snapshot.fetch(:content))
          File.chmod(snapshot.fetch(:mode), path)
          true
        when :symlink
          FileUtils.rm_rf(path)
          FileUtils.mkdir_p(File.dirname(path))
          File.symlink(snapshot.fetch(:target), path)
          true
        when :directory
          FileUtils.rm_rf(path) if File.exist?(path) && !File.directory?(path)
          FileUtils.mkdir_p(path)
          File.chmod(snapshot.fetch(:mode), path)
          true
        else
          false
        end
      end

      def report_partial_init_rollback(ops, results, errors)
        return if results.empty? && errors.empty?

        if errors.empty?
          write_warn("hive: partial init failed; rolled back #{results.join(', ')}")
        else
          write_warn("hive: partial init failed; rollback incomplete: #{errors.join('; ')}")
          write_warn("hive: recover with: #{partial_init_recovery_command(ops)}")
        end
      end

      def rollback_error(command, out, err)
        detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
        detail.empty? ? "#{command} failed" : "#{command} failed: #{detail.lines.first.chomp}"
      end

      def partial_init_recovery_command(ops)
        worktree = Shellwords.join([ "git", "-C", @project_path, "worktree", "remove", ops.hive_state_path, "--force" ])
        branch = Shellwords.join([ "git", "-C", @project_path, "branch", "-D", Hive::GitOps::HIVE_BRANCH ])
        "#{worktree} && #{branch}"
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

      def emit_json_summary(entry:, ops:, answers:)
        puts JSON.generate(success_payload(entry: entry, ops: ops, answers: answers))
      rescue Errno::EPIPE
        nil
      end

      def success_payload(entry:, ops:, answers:)
        {
          "schema" => "hive-init",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-init"),
          "ok" => true,
          "project" => entry.fetch("name"),
          "path" => entry.fetch("path"),
          "default_branch" => ops.default_branch,
          "hive_state_path" => entry.fetch("hive_state_path"),
          "worktree_root" => worktree_root,
          "answers" => answers,
          "planning_agent" => answers.fetch("planning_agent"),
          "claude_mode" => answers.fetch("claude_mode", Hive::Commands::Init::Prompts::DEFAULT_CLAUDE_MODE),
          "development_agent" => answers.fetch("development_agent"),
          "enabled_reviewers" => answers.fetch("enabled_reviewers"),
          "patrol_reviewers" => answers.fetch("patrol_reviewers"),
          "patrol_mode" => answers.fetch("patrol_mode", Hive::Commands::Init::Prompts::DEFAULT_PATROL_MODE),
          "triage_bias" => answers.fetch("triage_bias", Hive::Commands::Init::Prompts::DEFAULT_TRIAGE_BIAS),
          "budgets" => answers.fetch("budgets"),
          "timeouts" => answers.fetch("timeouts"),
          "daemon_enabled" => answers.fetch("daemon_enabled", true),
          "babysitter_enabled" => answers.fetch("babysitter_enabled", true),
          "daemon_autostart_requested" => answers.fetch("daemon_autostart", false)
        }
      end

      def print_summary(entry:, ops:, answers:)
        c = Palette.for($stdout)
        name = entry["name"]
        rows = [
          [ "project",        @project_path ],
          [ "default branch", ops.default_branch ],
          [ "hive state",     ops.hive_state_path ],
          [ "worktree root",  worktree_root ],
          [ "daemon",         answers.fetch("daemon_enabled", true) ? "enabled" : "disabled" ],
          [ "babysitter",     answers.fetch("babysitter_enabled", true) ? "enabled" : "disabled" ]
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
        summary_io = @json ? StringIO.new : $stdout
        prompts = @prompts || Hive::Commands::Init::Prompts.new(input: $stdin, output: $stderr, summary_io: summary_io)
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

      def render_project_config(ops, answers:, default_workflow: Hive::Workflows::CODING_ID)
        require "erb"
        template = File.read(File.expand_path("../../../templates/project_config.yml.erb", __dir__))
        bindings = ProjectConfigBinding.new(
          project_name: File.basename(@project_path),
          default_branch: ops.default_branch,
          worktree_root: worktree_root,
          answers: answers,
          default_workflow: default_workflow
        )
        ERB.new(template, trim_mode: "-").result(bindings.binding_for_erb)
      end

      def worktree_root
        Hive::Worktree.default_worktree_root(File.basename(@project_path))
      end

      def resolve_workflow_choice(ops)
        if @workflow_name
          return WorkflowChoice.new(
            descriptor: Hive::WorkflowSelection.fetch!(@workflow_name),
            source: :flag
          )
        end

        if @workflow_input.respond_to?(:tty?) && @workflow_input.tty?
          # On a re-init the prompt defaults to (and a bare Enter keeps) the
          # project's CURRENT default rather than coding — pressing Enter must
          # never silently reset a non-coding default back to coding and rebind
          # every field-less in-flight task. A fresh init defaults to coding.
          current = ops.hive_state_branch_exists? ? current_default_workflow(ops) : Hive::Workflows::CODING_ID.to_s
          return WorkflowChoice.new(descriptor: prompt_workflow(current), source: :prompt)
        end

        WorkflowChoice.new(descriptor: Hive::Workflows::Registry.default, source: :implicit)
      end

      def prompt_workflow(current_default = Hive::Workflows::CODING_ID.to_s)
        ids = Hive::WorkflowSelection.valid_names
        @workflow_output.puts "Workflows: #{ids.each_with_index.map { |name, index| "#{index + 1}) #{name}" }.join('  ')}"
        loop do
          @workflow_output.print "Default workflow [#{current_default}]: "
          @workflow_output.flush
          answer = @workflow_input.gets
          raise Hive::Commands::Init::Prompts::Aborted, "input closed" if answer.nil?

          value = answer.strip
          return Hive::WorkflowSelection.fetch!(current_default) if value.empty?

          resolved = resolve_workflow_answer(value, ids)
          return resolved if resolved

          @workflow_output.puts "  unknown workflow #{value.inspect}; pick a name (#{ids.join(', ')}) or 1..#{ids.size}"
        end
      end

      def resolve_workflow_answer(value, ids)
        if value.match?(/\A\d+\z/)
          index = value.to_i
          return Hive::WorkflowSelection.fetch!(ids[index - 1]) if index.between?(1, ids.size)

          return nil
        end

        match = ids.find { |id| id.casecmp(value).zero? }
        match && Hive::WorkflowSelection.fetch!(match)
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
      # claude_permission_mode / development_agent / enabled_reviewers /
      # patrol_reviewers / patrol_mode / triage_bias / budgets / timeouts /
      # daemon_enabled / babysitter_enabled / daemon_autostart). The single source of truth
      # for the answers hash is `Prompts#collect`; this binding never invents
      # defaults of its own — callers always supply `answers:` (production:
      # from Prompts; tests: explicit hashes).
      # Budget and timeout sections are also validated against the full
      # prompt LIMIT_KEYS set so nested prompt/template drift fails fast.
      class ProjectConfigBinding
        def initialize(project_name:, default_branch:, worktree_root:, answers:,
                       default_workflow: Hive::Workflows::CODING_ID)
          @project_name = project_name
          @default_branch = default_branch
          @worktree_root = worktree_root
          @default_workflow = default_workflow.to_s
          @planning_agent = answers.fetch("planning_agent")
          @claude_mode = answers.fetch("claude_mode")
          @claude_permission_mode = answers.fetch("claude_permission_mode")
          # Strict fetch like every other answer key (both the TTY prompts
          # and the web InitSetup always supply them); blank model falls
          # back to the tracking alias, and "default" effort renders as a
          # commented hint — the launcher omits the flag for it anyway.
          @claude_model = answers.fetch("claude_model")
                                 .to_s.strip.then { |v| v.empty? ? Hive::Commands::Init::Prompts::DEFAULT_CLAUDE_MODEL : v }
          @claude_effort = answers.fetch("claude_effort")
                                  .to_s.strip.then { |v| v.empty? || v == "default" ? nil : v }
          @development_agent = answers.fetch("development_agent")
          @enabled_reviewers = answers.fetch("enabled_reviewers")
          @patrol_reviewers = answers.fetch("patrol_reviewers")
          @patrol_mode = answers.fetch("patrol_mode")
          @triage_bias = answers.fetch("triage_bias")
          @budgets = required_limit_answers(answers.fetch("budgets"), "budgets")
          @timeouts = required_limit_answers(answers.fetch("timeouts"), "timeouts")
          @daemon_enabled = answers.fetch("daemon_enabled")
          @babysitter_enabled = answers.fetch("babysitter_enabled")
          @daemon_autostart = answers.fetch("daemon_autostart")
        end

        attr_reader :project_name, :default_branch, :worktree_root,
                    :default_workflow,
                    :planning_agent, :claude_mode, :claude_permission_mode,
                    :claude_model, :claude_effort, :development_agent,
                    :enabled_reviewers, :patrol_reviewers, :patrol_mode, :triage_bias, :budgets, :timeouts,
                    :daemon_enabled, :babysitter_enabled, :daemon_autostart

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
