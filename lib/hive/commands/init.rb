require "open3"
require "fileutils"
require "json"
require "pathname"
require "shellwords"
require "stringio"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/stages"
require "hive/task_meta"
require "hive/worktree"
require "hive/workflow_selection"
require "hive/workflows"
require "hive/workflows/loader"
require "hive/llm_wiki_bootstrap"
require "hive/commands/workflow"
require "hive/commands/init/prompts"
require "hive/commands/setup_agents"
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

      # Immutable value object (Data.define, matching the Workflow/Stage/
      # AdvanceVerb convention) carrying the resolved descriptor and the
      # provenance of the choice (:flag | :prompt | :implicit). The initialize
      # guard enforces the documented invariant at construction — descriptor is a
      # non-nil resolved Hive::Workflow and source is one of the three known
      # provenances — so a malformed choice fails here, not at a far-away read.
      WorkflowChoice = Data.define(:descriptor, :source) do
        def initialize(descriptor:, source:)
          raise ArgumentError, "WorkflowChoice descriptor must be a resolved workflow, got nil" if descriptor.nil?
          unless self.class::SOURCES.include?(source)
            raise ArgumentError, "WorkflowChoice source must be one of #{self.class::SOURCES.join(', ')} (got #{source.inspect})"
          end

          super
        end
      end
      # The closed set of provenances a WorkflowChoice may carry. Defined on the
      # value object itself (not the bare lexical Init::SOURCES an in-block
      # assignment would bind) so it reads as WorkflowChoice::SOURCES; the
      # initialize guard reaches it through self.class::SOURCES.
      WorkflowChoice::SOURCES = %i[flag prompt implicit].freeze
      CUSTOM_WORKFLOW_HINT_COMMAND = "hive workflow new <id>".freeze
      CUSTOM_WORKFLOW_HINT_MESSAGE = "custom workflows live in this project — author one with `#{CUSTOM_WORKFLOW_HINT_COMMAND}`".freeze

      def initialize(project_path, force: false, json: false, prompts: nil,
                     workflow: nil, new_workflow: nil, refactor_patrol: nil,
                     workflow_input: $stdin, workflow_output: $stderr,
                     provisioning_input: $stdin, provisioning_output: $stdout,
                     provisioning_error: $stderr, preflight_inspector: nil,
                     setup_agents_factory: nil)
        @project_path = File.expand_path(project_path)
        @force = force
        @json = json
        @workflow_name = workflow
        @new_workflow = new_workflow
        unless refactor_patrol.nil? || [ true, false ].include?(refactor_patrol)
          raise ArgumentError, "refactor_patrol must be true, false, or nil"
        end
        @refactor_patrol = refactor_patrol
        @workflow_input = workflow_input
        @workflow_output = workflow_output
        @provisioning_input = provisioning_input
        @provisioning_output = provisioning_output
        @provisioning_error = provisioning_error
        @preflight_inspector = preflight_inspector
        @setup_agents_factory = setup_agents_factory || lambda do |**kwargs|
          Hive::Commands::SetupAgents.new(**kwargs)
        end
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
        # Argument-level mutual exclusivity is checked before validate_clean_tree!
        # so a dirty repo passing both flags gets the clearer usage error instead
        # of the clean-tree complaint (both still exit non-zero).
        if @workflow_name && @new_workflow
          raise Hive::Commands::Workflow::UsageError, "--workflow and --new-workflow are mutually exclusive"
        end
        validate_clean_tree! unless @force

        ops = Hive::GitOps.new(@project_path)
        reject_existing_refactor_patrol_selector!(ops)
        if @new_workflow
          init_with_new_workflow(ops)
          return
        end

        workflow_choice = resolve_workflow_choice(ops)
        if workflow_choice.nil?
          # nil (not a WorkflowChoice) is resolve_workflow_choice's signal that the
          # interactive prompt's "author a new workflow" entry was chosen: deep
          # inside it, prompt_workflow set @new_workflow as a side effect.
          # Inline authoring deliberately routes through the same scaffolder as
          # --new-workflow — the descriptor does not exist yet, so there is no
          # resolved Hive::Workflow to carry in a WorkflowChoice. Keying off the
          # return value (not a re-read of @new_workflow) keeps routing data-driven.
          init_with_new_workflow(ops)
          return
        end
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
        entry = initialize_project_state(
          ops,
          content: project_config_content,
          workflow: workflow_choice.descriptor.id
        )

        if @json
          emit_json_summary(entry: entry, ops: ops, answers: answers, workflow: workflow_choice.descriptor.id)
        else
          print_summary(entry: entry, ops: ops, answers: answers, workflow: workflow_choice.descriptor.id)
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

      def init_with_new_workflow(ops)
        id = Hive::Commands::Workflow.normalize_and_validate_id!(@new_workflow)
        if ops.hive_state_branch_exists?
          scaffold_and_bind_existing(ops, id)
        else
          scaffold_and_bind_fresh(ops, id)
        end
      end

      def reject_existing_refactor_patrol_selector!(ops)
        return if @refactor_patrol.nil? || !ops.hive_state_branch_exists?

        selector = @refactor_patrol ? "--refactor-patrol" : "--no-refactor-patrol"
        raise Hive::ConfigError,
              "hive init #{selector} is only valid for a fresh project; " \
              "edit refactor_patrol.enabled in #{File.join(ops.hive_state_path, 'config.yml')} for an existing project"
      end

      def scaffold_and_bind_fresh(ops, id)
        answers = collect_prompt_answers
        project_config_content = render_project_config(ops, answers: answers, default_workflow: id)
        scaffold = nil
        entry = initialize_project_state(ops, content: project_config_content) do
          scaffold = scaffold_descriptor_commit!(ops, id)
        end

        paths = scaffold.fetch(:paths)
        if @json
          emit_json_summary(entry: entry, ops: ops, answers: answers, workflow: id,
                            extra: scaffold_payload(paths))
        else
          print_summary(entry: entry, ops: ops, answers: answers, workflow: id, scaffold_paths: paths)
        end
        register_daemon_service!(autostart: answers.fetch("daemon_autostart", false))
        run_init_preflight!
      end

      def scaffold_descriptor_commit!(ops, id)
        scaffold = nil
        begin
          scaffold = Hive::Commands::Workflow.scaffold_files!(id, project_root: @project_path)
          paths = scaffold.fetch(:paths)
          Hive::Lock.with_commit_lock(ops.hive_state_path) do
            # Commit config.yml alongside the descriptor so the fresh
            # `default_workflow: <id>` binding is durable against a hive-state
            # `git reset --hard`/`clean` — symmetric with the existing-project
            # path. A commit failure here tears the whole worktree down via
            # rollback_partial_init, so no staged index can leak.
            Hive::Commands::Workflow.commit_workflow_scaffold(
              ops, slug: id, pathspecs: scaffold_commit_pathspecs(paths, ops)
            )
          end
          scaffold
        rescue StandardError
          # Re-derive paths from `scaffold` rather than the local `paths` (bound
          # just above): if scaffold_files! raised before its assignment, the
          # local is unset — the `if scaffold` guard makes this the only safe read.
          Hive::Commands::Workflow.rollback_scaffold(scaffold.fetch(:paths)) if scaffold
          raise
        end
      end

      def scaffold_and_bind_existing(ops, id)
        ops.ensure_hive_state_worktree_attached
        scaffold = Hive::Commands::Workflow.scaffold_files!(id, project_root: @project_path)
        paths = scaffold.fetch(:paths)
        cfg_path = File.join(ops.hive_state_path, "config.yml")
        pathspecs = scaffold_commit_pathspecs(paths, ops)
        begin
          Hive::Lock.with_commit_lock(ops.hive_state_path) do
            current, corrupt = current_default_workflow_with_status(ops)
            warn_on_fieldless_tasks_rebinding(ops, from: current, to: id) unless current == id && !corrupt
            before = File.exist?(cfg_path) ? File.binread(cfg_path) : :absent
            write_default_workflow!(cfg_path, id)
            begin
              Hive::Commands::Workflow.commit_workflow_scaffold(ops, slug: id, pathspecs: pathspecs)
            rescue StandardError
              # hive_commit stages config.yml + descriptor + instruction dir via
              # a per-pathspec `git add -A -- <path>` before it runs; a failure
              # AFTER staging leaves those entries in the long-lived .hive-state
              # index, where the next bare `git commit` would sweep the
              # half-rolled-back default_workflow rebind (and a phantom
              # descriptor) into an unrelated commit. Reset the index for those
              # pathspecs and restore config.yml INSIDE the commit lock —
              # mirroring update_existing_default_workflow! — so a concurrent
              # committer (e.g. the daemon committing a task) cannot acquire the
              # lock between the failed commit and the reset and ride the
              # still-staged rebind into a foreign commit.
              reset_hive_state_index(ops, pathspecs)
              restore_config_snapshot(cfg_path, before)
              raise
            end
          end
        rescue StandardError
          # Filesystem-only scaffold teardown stays outside the lock: it removes
          # working-tree files, not index entries, so it cannot be swept into a
          # concurrent commit.
          Hive::Commands::Workflow.rollback_scaffold(paths)
          raise
        end

        Hive::Config.register_project(name: File.basename(@project_path), path: @project_path)
        # Carry the real, now-on-disk descriptor (like handle_existing_project)
        # instead of a one-field stand-in, so WorkflowChoice's "descriptor is a
        # fully resolved Hive::Workflow" invariant holds on this path too.
        descriptor = Hive::WorkflowSelection.fetch!(id.to_s, project_root: @project_path)
        workflow_choice = WorkflowChoice.new(descriptor: descriptor, source: :flag)
        if @json
          emit_existing_json_summary(ops, workflow_choice: workflow_choice, extra: scaffold_payload(paths))
        else
          write_existing_summary(ops, workflow_choice: workflow_choice, scaffold_paths: paths)
        end
      end

      def handle_existing_project(ops, workflow_choice:)
        ops.ensure_hive_state_worktree_attached
        # `:implicit` re-init already raised AlreadyInitialized in `call` before
        # reaching here, so this path only sees :flag / :prompt — both express a
        # default-workflow intent and run the (idempotent) rebind.
        if workflow_choice.descriptor.id.to_s == "bench"
          install_and_rebind_existing_bench!(ops, workflow_choice.descriptor.id)
        else
          update_existing_default_workflow!(ops, workflow_choice.descriptor.id)
        end
        Hive::Config.register_project(name: File.basename(@project_path), path: @project_path)
        if @json
          emit_existing_json_summary(ops, workflow_choice: workflow_choice)
        else
          write_existing_summary(ops, workflow_choice: workflow_choice)
        end
      end

      def write_existing_summary(_ops, workflow_choice:, scaffold_paths: nil)
        name = File.basename(@project_path)
        $stdout.puts "hive: already initialized #{name}"
        $stdout.puts "workflow: #{workflow_choice.descriptor.id}"
        if scaffold_paths
          safe_name = Shellwords.escape(name)
          $stdout.puts "descriptor: #{scaffold_paths.fetch(:descriptor)}"
          $stdout.puts "edit: #{scaffold_paths.fetch(:instruction)}"
          $stdout.puts "next: edit the descriptor above, then hive new #{safe_name} '<idea>'"
        end
      rescue Errno::EPIPE
        nil
      end

      # An agent re-running `hive init --workflow X --json` on an existing
      # project would otherwise get exit 0 with EMPTY stdout — no confirmation
      # of the re-bind. Emit a minimal `already_initialized` hive-init payload
      # (a distinct oneOf arm from the fresh SuccessPayload in the schema).
      def emit_existing_json_summary(ops, workflow_choice:, extra: {})
        puts JSON.generate(existing_payload(ops, workflow_choice: workflow_choice).merge(extra))
      rescue Errno::EPIPE
        nil
      end

      def existing_payload(ops, workflow_choice:)
        {
          "schema" => "hive-init",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-init"),
          "ok" => true,
          "already_initialized" => true,
          "project" => File.basename(@project_path),
          "path" => @project_path,
          "hive_state_path" => ops.hive_state_path,
          "workflow" => workflow_choice.descriptor.id.to_s
        }
      end

      def update_existing_default_workflow!(ops, workflow_id)
        cfg_path = File.join(ops.hive_state_path, "config.yml")
        current, corrupt = current_default_workflow_with_status(ops)
        next_value = workflow_id.to_s
        # Idempotent confirm (A8): re-running with the SAME default is a clean
        # no-op — no warning, no rewrite, no commit. EXCEPT when `current` came
        # from the corrupt-config rescue (Config.load masks an unparseable file
        # as coding): there the operator's explicit `hive init --workflow X` is
        # a repair gesture, so force the rewrite even when X equals the masked
        # fallback, instead of leaving the broken file untouched.
        return if current == next_value && !corrupt

        warn_on_fieldless_tasks_rebinding(ops, from: current, to: next_value)
        # Mutate config.yml atomically and COMMIT it under the per-project
        # commit lock, like every other hive/state mutation. A bare File.write
        # left the hive/state worktree permanently dirty (a later reset/clean
        # silently reverted the default) and an interrupted write could truncate
        # config.yml — masked by Config.load's Psych-rescue → coding fallback.
        Hive::Lock.with_commit_lock(ops.hive_state_path) do
          # Snapshot the pre-write content so a commit failure AFTER atomic_write
          # has landed the rename can restore it — otherwise the move stays in
          # the worktree (dirty) and a later git reset/clean silently reverts the
          # default. Restore makes the mutation all-or-nothing.
          before = File.exist?(cfg_path) ? File.binread(cfg_path) : :absent
          write_default_workflow!(cfg_path, next_value)
          begin
            ops.hive_commit(
              stage_name: "config",
              slug: "default_workflow",
              action: "set to #{next_value}",
              pathspecs: [ "config.yml" ]
            )
          rescue StandardError
            restore_config_snapshot(cfg_path, before)
            raise
          end
        end
      end

      # Legacy bench migration changes three pieces of durable state: the
      # project-authored descriptor archive, the packaged runtime, and the
      # default_workflow binding. Keep them under Bench's single commit lock and
      # single scoped commit so a rejected commit or Ctrl-C restores all three.
      def install_and_rebind_existing_bench!(ops, workflow_id)
        cfg_path = File.join(ops.hive_state_path, "config.yml")
        config_before = nil
        config_mutated = false
        next_value = workflow_id.to_s
        before_commit = lambda do
          current, corrupt = current_default_workflow_with_status(ops)
          next if current == next_value && !corrupt

          warn_on_fieldless_tasks_rebinding(ops, from: current, to: next_value)
          Thread.handle_interrupt(Interrupt => :never) do
            config_before = File.exist?(cfg_path) ? File.binread(cfg_path) : :absent
            config_mutated = true
            write_default_workflow!(cfg_path, next_value)
          end
        end
        rollback = lambda do
          restore_config_snapshot!(cfg_path, config_before) if config_mutated
        end

        install_builtin_workflow_runtime!(
          ops,
          workflow_id,
          additional_pathspecs: -> { config_mutated ? [ "config.yml" ] : [] },
          before_commit: before_commit,
          rollback: rollback
        )
      end

      def restore_config_snapshot(cfg_path, before)
        restore_config_snapshot!(cfg_path, before)
      rescue StandardError => e
        # A failed restore must not mask the original commit error; surface it
        # and let the original (re-raised by the caller) propagate.
        write_warn("hive: could not restore config.yml after a failed default_workflow commit " \
                   "(#{e.class}: #{e.message}); re-run `hive init --workflow` to retry")
      end

      def restore_config_snapshot!(cfg_path, before)
        if before == :absent
          FileUtils.rm_f(cfg_path)
        else
          atomic_write(cfg_path, before)
        end
      end

      def current_default_workflow(ops)
        current_default_workflow_with_status(ops).first
      end

      # Returns [value, corrupt?]: the resolved default_workflow plus whether the
      # read fell through the corrupt-config rescue (so update_existing_default_workflow!
      # can override its idempotency short-circuit and repair an unparseable file).
      def current_default_workflow_with_status(ops)
        cfg_path = File.join(ops.hive_state_path, "config.yml")
        return [ Hive::Config::DEFAULTS["default_workflow"], false ] unless File.exist?(cfg_path)

        raw = YAML.safe_load(File.read(cfg_path)) || {}
        value = raw.is_a?(Hash) ? raw["default_workflow"].to_s.strip : ""
        [ value.empty? ? Hive::Config::DEFAULTS["default_workflow"] : value, false ]
      rescue Psych::Exception, SystemCallError => e
        # Don't silently assume coding on a corrupt config (unlike a clean
        # absent/blank value): the rebind warning would under-report and the
        # line-edit proceeds on an unparseable file. Surface it, mirroring
        # Task#load_project_default_workflow, and flag it corrupt so the caller
        # forces the repair rewrite.
        write_warn("hive: could not read default_workflow from #{cfg_path} " \
                   "(#{e.class}: #{e.message}); assuming #{Hive::Config::DEFAULTS['default_workflow']}")
        [ Hive::Config::DEFAULTS["default_workflow"], true ]
      end

      def write_default_workflow!(cfg_path, workflow_id)
        FileUtils.mkdir_p(File.dirname(cfg_path))
        content = File.exist?(cfg_path) ? File.read(cfg_path) : "---\n"
        lines = content.lines
        existing = lines.index { |line| line.match?(/\Adefault_workflow:/) }

        if Hive::Workflows.coding_id?(workflow_id)
          lines.delete_at(existing) if existing
        elsif existing
          lines[existing] = default_workflow_line(workflow_id)
        else
          lines.insert(default_workflow_insert_index(lines), default_workflow_line(workflow_id))
        end

        atomic_write(cfg_path, lines.join)
      end

      # Quote the emitted scalar: YAML.safe_load coerces bare keyword-like ids
      # (yes/on/no/off/null/true/false — all valid SAFE_SLUG workflow ids) to
      # booleans/nil, so a flag-less `hive new` would then fail to resolve them.
      # The id is a validated SAFE_SLUG (alnum + hyphen), so double-quoting never
      # needs escaping.
      #
      # This is the REBIND path. The fresh-render path encodes the SAME quoting
      # invariant in templates/project_config.yml.erb (its `default_workflow:`
      # line). Keep the two in sync — a change to one (different quote style,
      # YAML-escaping, …) must be mirrored in the other so the paths cannot
      # silently desync.
      def default_workflow_line(workflow_id)
        %(default_workflow: "#{workflow_id}"\n)
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
        terminal_dirs = Hive::Workflows.all_terminal_stage_dirs
        Dir.glob(File.join(stages_root, "*", "*")).sort.filter_map do |path|
          next unless File.directory?(path)
          next unless Hive::Stages.task_slug?(File.basename(path))

          stage_dir = File.basename(File.dirname(path))
          next if terminal_dirs.include?(stage_dir)
          next if Hive::TaskMeta.read(path)[:workflow]

          File.join(stage_dir, File.basename(path))
        end
      end

      def initialize_project_state(ops, content:, workflow: nil, &after_bootstrap)
        rollback_on_failure = false
        side_effect_snapshot = capture_init_side_effect_snapshot
        begin
          rollback_on_failure = true
          init_result = ops.hive_state_init
          rollback_on_failure = init_result == :created
          write_per_project_config(ops, content: content)
          install_builtin_workflow_runtime!(ops, workflow)
          ops.add_hive_state_to_master_gitignore!
          Hive::LlmWikiBootstrap.install!(@project_path, post_commit_hook: false, scheduler: false)
          ops.commit_llm_wiki_bootstrap!
          Hive::LlmWikiBootstrap.install_runtime_hooks!(@project_path)

          entry = Hive::Config.register_project(name: File.basename(@project_path), path: @project_path)
          after_bootstrap&.call
          entry
        rescue StandardError
          rollback_partial_init(ops, side_effect_snapshot: side_effect_snapshot) if rollback_on_failure
          raise
        end
      end

      def install_builtin_workflow_runtime!(ops, workflow_id, **options)
        return unless workflow_id.to_s == "bench"

        Hive::Workflows::Bench.install_runtime!(ops, **options)
        # A legacy project descriptor may have been archived by install_runtime!.
        # Drop the process-local overlay/cache so later same-process task reads
        # resolve the newly installed built-in instead of the now-absent file.
        Hive::Workflows::Project.reset!
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

      # Non-transactional post-init aid. The shared inspector diagnoses the
      # freshly written effective config. A TTY may delegate accepted repair
      # to SetupAgents with recorded consent; JSON/non-TTY flows only report
      # remediation, and setup failures never roll back project creation.
      #
      # Rescue scope: `StandardError` for verifier bugs (with a
      # bug-report hint in the warning so silent swallow is mitigated).
      # `Errno::EPIPE` rescued narrowly around `warn` so a
      # `hive init | head` pattern doesn't crash. `Interrupt` and
      # `SystemExit` propagate (Ctrl-C honored as user intent).
      def run_init_preflight!
        cfg = Hive::Config.load(@project_path)
        inspector = @preflight_inspector || Hive::AgentSkills::Inspector.new(
          config: cfg,
          project_root: @project_path
        )
        rows = inspector.inspect
        actionable = rows.select do |row|
          row.managed && %w[missing stale incompatible conflicting].include?(row.health)
        end
        return if actionable.empty?

        unless interactive_provisioning?
          emit_preflight_warnings(actionable)
          return
        end

        @provisioning_error.print "Provision unresolved agent skills now? [y/N]: "
        @provisioning_error.flush
        answer = @provisioning_input.gets.to_s.strip.downcase
        unless %w[y yes].include?(answer)
          emit_preflight_warnings(actionable)
          return
        end

        setup = @setup_agents_factory.call(
          config: cfg,
          project_root: @project_path,
          consent_provenance: "init_interactive",
          input: @provisioning_input,
          output: @provisioning_output,
          error: @provisioning_error
        )
        exit_code = setup.call
        return if exit_code.zero?

        @provisioning_error.puts "hive: optional agent skill setup finished with exit #{exit_code}; " \
                                 "the project remains initialized. Re-run `hive setup-agents`."
      rescue Hive::ConfigError => e
        @provisioning_error.puts "hive: doctor pre-flight — config issue detected (#{e.message}); " \
                                 "run `hive doctor` for details"
      rescue StandardError => e
        emit_preflight_bug(e)
      end

      def interactive_provisioning?
        return false if @json
        @provisioning_input.respond_to?(:tty?) && @provisioning_input.tty?
      rescue IOError
        false
      end

      def emit_preflight_warnings(rows)
        @provisioning_error.puts "hive: doctor pre-flight — found #{rows.size} issue(s):"
        rows.each do |row|
          label = row.surfaces.join(",")
          @provisioning_error.puts "  [#{label}/#{row.agent}] #{row.explanation}"
          @provisioning_error.puts "    repair: #{row.remediation}" if row.remediation
        end
        @provisioning_error.puts "  See `hive doctor` for details or run `hive setup-agents`."
      rescue Errno::EPIPE
        nil
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

      def emit_json_summary(entry:, ops:, answers:, workflow:, extra: {})
        puts JSON.generate(success_payload(entry: entry, ops: ops, answers: answers, workflow: workflow).merge(extra))
      rescue Errno::EPIPE
        nil
      end

      def success_payload(entry:, ops:, answers:, workflow:)
        {
          "schema" => "hive-init",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-init"),
          "ok" => true,
          "project" => entry.fetch("name"),
          "path" => entry.fetch("path"),
          "default_branch" => ops.default_branch,
          "hive_state_path" => entry.fetch("hive_state_path"),
          # The bound default workflow, mirroring AlreadyInitializedPayload's
          # `workflow` field — so an agent running `hive init --workflow X --json`
          # on a fresh project can confirm the binding from JSON instead of
          # reading config.yml out of band.
          "workflow" => workflow.to_s,
          "hints" => workflow_authoring_hints(entry.fetch("hive_state_path"), workflow),
          "worktree_root" => worktree_root,
          "answers" => answers,
          "planning_agent" => answers.fetch("planning_agent"),
          "claude_mode" => answers.fetch("claude_mode", Hive::Commands::Init::Prompts::DEFAULT_CLAUDE_MODE),
          "development_agent" => answers.fetch("development_agent"),
          "enabled_reviewers" => answers.fetch("enabled_reviewers"),
          "patrol_reviewers" => answers.fetch("patrol_reviewers"),
          "patrol_mode" => answers.fetch("patrol_mode", Hive::Commands::Init::Prompts::DEFAULT_PATROL_MODE),
          "triage_bias" => answers.fetch("triage_bias", Hive::Commands::Init::Prompts::DEFAULT_TRIAGE_BIAS),
          "adhoc_auto_fix" => answers.fetch("adhoc_auto_fix", Hive::Commands::Init::Prompts::DEFAULT_ADHOC_AUTO_FIX),
          "refactor_patrol_enabled" => answers.fetch("refactor_patrol_enabled"),
          "budgets" => answers.fetch("budgets"),
          "timeouts" => answers.fetch("timeouts"),
          "daemon_enabled" => answers.fetch("daemon_enabled", true),
          "babysitter_enabled" => answers.fetch("babysitter_enabled", true),
          "daemon_autostart_requested" => answers.fetch("daemon_autostart", false)
        }
      end

      def no_custom_workflow_yet?(hive_state_path, workflow)
        Hive::Workflows.coding_id?(workflow) &&
          Hive::Workflows::Loader.load_dir(File.join(hive_state_path, "workflows")).empty?
      rescue StandardError => e
        # The workflow-authoring hint is purely advisory and computed in
        # success_payload/print_summary, which run AFTER init has already
        # committed the hive/state branch and BEFORE register_daemon_service! /
        # run_init_preflight!. This deliberately catches the whole StandardError
        # surface, not only the filesystem faults it primarily guards against (an
        # unlisted SystemCallError escaping File.directory?/Dir.glob, or an
        # invalid-byte path raising ArgumentError/EncodingError): a genuine
        # programming bug here too (a NoMethodError/KeyError/TypeError in the
        # coding_id?/load_dir/DescriptorParser chain) would otherwise bubble to
        # call's `rescue StandardError → InternalError` and turn an
        # already-committed init into a crash that skips those two best-effort
        # steps. Degrade to "no hint" with a breadcrumb (carrying the same
        # bug-report pointer as the sibling register_daemon_service! /
        # run_init_preflight! guards, since the arm also catches genuine
        # programming bugs) — the same rescue-and-warn guard those two apply to
        # their own post-commit, best-effort work. (No Hive::ConfigError can reach
        # this arm: coding_id? is pure and Loader.load_dir swallows per-file
        # ConfigError internally, never calling Config.load. But since
        # Hive::ConfigError < StandardError this rescue WOULD swallow one if a
        # future config read were added here — it offers no re-raise guarantee, so
        # surface such a read's failure deliberately rather than trusting this net.)
        write_warn(
          "hive: skipped workflow-authoring hint (#{e.class}: #{e.message}) " \
          "(this may be a hive bug, please report at " \
          "https://github.com/ivankuznetsov/hive/issues)"
        )
        false
      end

      def workflow_authoring_hints(hive_state_path, workflow)
        return [] unless no_custom_workflow_yet?(hive_state_path, workflow)

        [
          {
            "kind" => "custom_workflow",
            "command" => CUSTOM_WORKFLOW_HINT_COMMAND,
            "message" => CUSTOM_WORKFLOW_HINT_MESSAGE
          }
        ]
      end

      def scaffold_payload(paths)
        {
          "descriptor_path" => paths.fetch(:descriptor),
          "instruction_path" => paths.fetch(:instruction)
        }
      end

      def print_summary(entry:, ops:, answers:, workflow: nil, scaffold_paths: nil)
        c = Palette.for($stdout)
        name = entry["name"]
        rows = [
          [ "project",        @project_path ],
          [ "default branch", ops.default_branch ],
          [ "hive state",     ops.hive_state_path ],
          [ "worktree root",  worktree_root ],
          [ "ad-hoc auto-fix", answers.fetch("adhoc_auto_fix", Hive::Commands::Init::Prompts::DEFAULT_ADHOC_AUTO_FIX) ? "enabled" : "disabled" ],
          [ "architecture patrol", answers.fetch("refactor_patrol_enabled") ? "enabled" : "disabled" ],
          [ "daemon",         answers.fetch("daemon_enabled", true) ? "enabled" : "disabled" ],
          [ "babysitter",     answers.fetch("babysitter_enabled", true) ? "enabled" : "disabled" ]
        ]
        if scaffold_paths
          rows += [
            [ "workflow",   workflow ],
            [ "descriptor", scaffold_paths.fetch(:descriptor) ],
            [ "edit",       scaffold_paths.fetch(:instruction) ]
          ]
        end
        label_width = rows.map { |k, _| k.length }.max

        $stdout.puts "#{c.green('✔')} #{c.bold('hive: initialized')} #{c.bold_cyan(name)}"
        rows.each do |label, value|
          $stdout.puts "  #{c.dim(label.ljust(label_width))}  #{value}"
        end
        $stdout.puts
        safe_name = Shellwords.escape(name)
        next_step =
          if scaffold_paths
            "edit the descriptor above, then hive new #{safe_name} '<idea>'"
          else
            "hive new #{safe_name} '<short task description>'"
          end
        $stdout.puts "#{c.cyan('→')} #{c.bold('next:')} #{next_step}"
        if no_custom_workflow_yet?(entry.fetch("hive_state_path"), workflow)
          $stdout.puts "  #{c.dim('tip:')} #{CUSTOM_WORKFLOW_HINT_MESSAGE}"
        end
      end

      def collect_prompt_answers
        summary_io = @json ? StringIO.new : $stdout
        prompts = @prompts || Hive::Commands::Init::Prompts.new(
          input: $stdin,
          output: $stderr,
          summary_io: summary_io,
          refactor_patrol_enabled: @refactor_patrol
        )
        answers = prompts.collect
        answers["refactor_patrol_enabled"] = @refactor_patrol unless @refactor_patrol.nil?
        answers
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
            descriptor: Hive::WorkflowSelection.fetch!(@workflow_name, project_root: @project_path),
            source: :flag
          )
        end

        # Only prompt when there's a real choice to make. With a single
        # registered workflow the numbered prompt offers no alternative yet still
        # blocks on stdin, which can hang a PTY-allocating wrapper (tmux /
        # `script` / expect). Treat size==1 as :implicit (coding default).
        if @workflow_input.respond_to?(:tty?) && @workflow_input.tty?
          workflow_names = Hive::WorkflowSelection.valid_names(project_root: @project_path)
          return WorkflowChoice.new(descriptor: Hive::Workflows::Registry.default, source: :implicit) unless workflow_names.size > 1

          # On a re-init the prompt defaults to (and a bare Enter keeps) the
          # project's CURRENT default rather than coding — pressing Enter must
          # never silently reset a non-coding default back to coding and rebind
          # every field-less in-flight task. A fresh init defaults to coding.
          current = ops.hive_state_branch_exists? ? current_default_workflow(ops) : Hive::Workflows::CODING_ID.to_s
          descriptor = prompt_workflow(current)
          # A nil descriptor means the operator picked "author a new workflow":
          # prompt_workflow set @new_workflow as a side effect and no resolved
          # Hive::Workflow exists yet. Return nil so `call` routes to the
          # scaffolder, rather than building a WorkflowChoice(descriptor: nil)
          # that would violate the type's "descriptor is a fully resolved
          # Hive::Workflow" invariant and rely on a downstream re-read of the flag.
          return if descriptor.nil?

          return WorkflowChoice.new(descriptor: descriptor, source: :prompt)
        end

        WorkflowChoice.new(descriptor: Hive::Workflows::Registry.default, source: :implicit)
      end

      def prompt_workflow(current_default = Hive::Workflows::CODING_ID.to_s)
        ids = Hive::WorkflowSelection.valid_names(project_root: @project_path)
        author_index = ids.size + 1
        choices = ids.each_with_index.map { |name, index| "#{index + 1}) #{name}" }
        choices << "#{author_index}) author a new workflow"
        @workflow_output.puts "Workflow:"
        @workflow_output.puts "  #{choices.join('  ')}"
        loop do
          @workflow_output.print "Default workflow [#{current_default}]: "
          @workflow_output.flush
          answer = @workflow_input.gets
          raise Hive::Commands::Init::Prompts::Aborted, "input closed" if answer.nil?

          value = answer.strip
          return Hive::WorkflowSelection.fetch!(current_default, project_root: @project_path) if value.empty?
          if numeric_choice(value) == author_index
            @new_workflow = prompt_new_workflow_id
            return nil
          end

          resolved = resolve_workflow_answer(value, ids)
          return resolved if resolved

          @workflow_output.puts "  unknown workflow #{value.inspect}; pick a name (#{ids.join(', ')}) " \
                                "or 1..#{author_index}"
        end
      end

      def prompt_new_workflow_id
        loop do
          @workflow_output.print "New workflow id: "
          @workflow_output.flush
          answer = @workflow_input.gets
          raise Hive::Commands::Init::Prompts::Aborted, "input closed" if answer.nil?

          id = Hive::Commands::Workflow.normalize_and_validate_id!(answer)
          if Hive::Commands::Workflow.scaffold_collision?(id, project_root: @project_path)
            @workflow_output.puts "  workflow scaffold already exists for #{id.inspect}"
            next
          end

          return id
        rescue Hive::Commands::Workflow::UsageError => e
          @workflow_output.puts "  #{e.message}"
        end
      end

      def resolve_workflow_answer(value, ids)
        index = numeric_choice(value)
        if index
          return Hive::WorkflowSelection.fetch!(ids[index - 1], project_root: @project_path) if index.between?(1, ids.size)

          return nil
        end

        match = ids.find { |id| id.casecmp(value).zero? }
        match && Hive::WorkflowSelection.fetch!(match, project_root: @project_path)
      end

      # Parse a workflow-prompt answer as a 1-based menu index, or nil when it is
      # not a bare integer (so a workflow *named* like a number, or any
      # non-numeric pick, falls through to name matching). Base 10 is pinned so a
      # leading-zero answer like "010" reads as 10, not octal 8.
      def numeric_choice(value)
        Integer(value, 10, exception: false)
      end

      def relative_to_hive_state(path, ops)
        Pathname.new(path).relative_path_from(Pathname.new(ops.hive_state_path)).to_s
      end

      # The descriptor + instruction dir + config.yml pathspecs every
      # --new-workflow scaffold commit pins. Both the fresh and existing-project
      # paths bind default_workflow in config.yml, committed atomically with the
      # descriptor so the binding is durable against a hive-state reset/clean.
      def scaffold_commit_pathspecs(paths, ops)
        [
          relative_to_hive_state(paths.fetch(:descriptor), ops),
          relative_to_hive_state(paths.fetch(:instruction_dir), ops),
          "config.yml"
        ]
      end

      # Unstage the scaffold pathspecs from the long-lived .hive-state index
      # after a failed --new-workflow commit, so a half-rolled-back rebind can't
      # ride the next unrelated `git commit`. Best-effort: a reset failure is
      # surfaced but never masks the original commit error the caller re-raises.
      def reset_hive_state_index(ops, pathspecs)
        _out, err, status = Open3.capture3(
          "git", "-C", ops.hive_state_path, "reset", "-q", "--", *pathspecs
        )
        return if status.success?

        # Surface git's FULL stderr (newlines flattened to one warn line): the
        # actionable detail — e.g. index.lock contention — often lands on a line
        # AFTER the first, so truncating to `lines.first` could drop exactly the
        # part the operator needs to act on.
        detail = err.to_s.strip.gsub(/\s*\n+\s*/, "; ")
        write_warn("hive: could not unstage #{pathspecs.join(', ')} after a failed " \
                   "--new-workflow commit (#{detail}); inspect " \
                   "`git -C #{ops.hive_state_path} status` before the next hive commit")
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
      # patrol_reviewers / patrol_mode / triage_bias / adhoc_auto_fix /
      # refactor_patrol_enabled /
      # budgets / timeouts / daemon_enabled / babysitter_enabled /
      # daemon_autostart). The single source of truth
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
          @adhoc_auto_fix = answers.fetch("adhoc_auto_fix")
          @refactor_patrol_enabled = answers.fetch("refactor_patrol_enabled")
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
                    :enabled_reviewers, :patrol_reviewers, :patrol_mode, :triage_bias, :adhoc_auto_fix,
                    :refactor_patrol_enabled, :budgets, :timeouts,
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
