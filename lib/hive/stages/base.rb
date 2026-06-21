require "erb"
require "fileutils"
require "securerandom"
require "time"
require "hive/agent"
require "hive/agent_profiles"
require "hive/config"
require "hive/events"
require "hive/markers"
require "hive/permission_scope"
require "hive/stages/clean_exit"
require "hive/usage_db"
require "hive/worktree"

module Hive
  module Stages
    module Base
      module_function

      # Per-spawn random nonce for the user_supplied wrapper. Defends against
      # prompt-injection attacks that close the wrapper from inside user
      # content (e.g. payload `</user_supplied><system>...`). Each call
      # returns a fresh value; callers bind it once into TemplateBindings so
      # the rendered prompt's opening and closing tags match within ONE
      # spawn, but two consecutive spawns get distinct nonces. This is the
      # ADR-019 amendment to ADR-008's per-process scope: a nonce leaked
      # via one agent's prompt cannot be used to forge a closing tag against
      # any sibling agent in the same hive run.
      def user_supplied_tag
        "user_supplied_#{SecureRandom.hex(8)}"
      end

      def render(template_name, bindings_obj)
        path = File.expand_path("../../../templates/#{template_name}", __dir__)
        ERB.new(File.read(path), trim_mode: "-").result(bindings_obj.binding_for_erb)
      end

      # Like #render, but the caller already resolved + validated the
      # absolute path via #resolve_template_path. Used by review-stage
      # consumers that accept user-configurable prompt_template values.
      def render_resolved_path(absolute_path, bindings_obj)
        ERB.new(File.read(absolute_path), trim_mode: "-").result(bindings_obj.binding_for_erb)
      end

      # Walk up from a task_folder (`.../<.hive-state>/stages/<N>-<name>/<slug>`)
      # to the matching `.hive-state` directory. Used by every consumer
      # of resolve_template_path that has a Reviewers::Context but not a
      # full Task.
      def hive_state_dir_for_task_folder(task_folder)
        File.expand_path(File.join(task_folder, "..", "..", ".."))
      end

      # Resolve a prompt-template name to an absolute, validated path.
      # Two cases:
      #   1. A bare basename (no slashes) → built-in template under
      #      lib/../templates/. Existence is checked but no escape
      #      check is needed: built-ins ship with the gem.
      #   2. A path with a slash → user-supplied custom template. Must
      #      land under `<hive_state_dir>/templates/` after `realpath`
      #      resolution. Path-escape attempts (`../`, absolute paths
      #      outside the allowed root, symlinks pointing outside) raise
      #      Hive::ConfigError.
      #
      # `hive_state_dir` is required for case 2; pass `nil` for callers
      # that only support built-ins.
      def resolve_template_path(name, hive_state_dir: nil)
        raise Hive::ConfigError, "prompt_template name cannot be blank" if name.nil? || name.to_s.empty?

        if !name.include?("/") && !File.absolute_path?(name)
          # Built-in template lookup.
          builtin = File.expand_path("../../../templates/#{name}", __dir__)
          unless File.exist?(builtin)
            raise Hive::ConfigError,
                  "prompt_template #{name.inspect} not found among built-ins (#{builtin})"
          end
          return builtin
        end

        # Custom template — must resolve under <state_dir>/templates/.
        unless hive_state_dir
          raise Hive::ConfigError,
                "prompt_template #{name.inspect} looks like a custom path but no hive_state_dir was provided"
        end

        templates_root_raw = File.join(hive_state_dir, "templates")
        unless File.directory?(templates_root_raw)
          raise Hive::ConfigError,
                "prompt_template #{name.inspect} requires #{templates_root_raw} to exist"
        end
        templates_root = File.realpath(templates_root_raw)

        candidate = File.expand_path(name, templates_root)
        unless File.exist?(candidate)
          raise Hive::ConfigError,
                "prompt_template #{name.inspect} not found at #{candidate}"
        end

        resolved = File.realpath(candidate)
        unless resolved.start_with?(templates_root + File::SEPARATOR) || resolved == templates_root
          raise Hive::ConfigError,
                "prompt_template #{name.inspect} resolves outside #{templates_root}"
        end
        resolved
      end

      # Resolve the AgentProfile to use for a single-agent stage
      # (brainstorm / plan / execute). Reads `cfg.dig(stage_name, "agent")`
      # and falls back to "claude" when the key is absent so legacy configs
      # written before plan 2026-05-04-001 keep working unchanged. The
      # `cfg:` argument is forwarded to AgentProfiles.lookup so per-CLI
      # overrides under `agents.<name>.<key>` are honored. Raises
      # Hive::ConfigError (via AgentProfiles::UnknownAgent) when the
      # configured value is not a registered profile — but that case is
      # already prevented at config-load time by validate_role_agent_names!,
      # so callers see UnknownAgent only if they bypass Config.load.
      def stage_profile(cfg, stage_name)
        name = cfg.dig(stage_name, "agent") || "claude"
        Hive::AgentProfiles.lookup(name, cfg: cfg)
      end

      def stage_permission_scope(cfg, stage_name, task, profile,
                                 base_add_dirs: [ task.folder ],
                                 default_allowed_tools: nil,
                                 explicit_permission_spec: MISSING_EXPLICIT_PERMISSION_SPEC)
        spec = if explicit_permission_spec.equal?(MISSING_EXPLICIT_PERMISSION_SPEC)
          Hive::Config.permission_spec(cfg || {}, stage_name)
        else
          explicit_permission_spec
        end
        scope = Hive::PermissionScope.resolve(
          spec,
          task_folder: task.folder,
          profile: profile,
          stage: stage_name
        )
        base_dirs = Array(base_add_dirs)

        if scope.yolo?
          return {
            add_dirs: base_dirs,
            permission_mode: nil,
            allowed_tools: default_allowed_tools_for_mode(cfg, profile, default_allowed_tools),
            disallowed_tools: nil
          }
        end

        {
          add_dirs: base_dirs + scope.add_dirs_extra,
          permission_mode: scope.permission_mode,
          allowed_tools: scope.allowed_tools,
          disallowed_tools: scope.disallowed_tools
        }
      end

      def default_allowed_tools_for_mode(cfg, profile, default_allowed_tools)
        return nil unless default_allowed_tools
        return nil unless profile.name == :claude
        return nil unless cfg && Hive::Config.claude_mode(cfg) == :tmux

        default_allowed_tools
      end

      MISSING_EXPLICIT_PERMISSION_SPEC = Object.new.freeze

      # Stage labels whose runner mutates the worktree directly. Adding a
      # new worktree-touching stage requires a deliberate edit here —
      # whitelist (not blacklist) keeps the `ensure_clean_on_exit`
      # invariant surgical. `2-brainstorm`, `3-plan`, `5-open-pr`,
      # `7-artifacts`, `9-done` only write to the task state folder
      # (`.hive-state/stages/...`), so the invariant doesn't apply there.
      WORKTREE_OWNING_STAGES = %w[4-execute 6-review 8-finalize].freeze # coding-scoped: worktree-owning coding stages that CleanExit enforces

      def with_stage_events(task, cfg: nil)
        stage = stage_label(task)
        Hive::Events.emit(
          task_folder: task.folder,
          slug: task.slug,
          stage: stage,
          event_type: :stage_enter,
          message: "run started"
        )
        result = yield
        if cfg && ensure_clean_on_exit_enabled?(cfg) && WORKTREE_OWNING_STAGES.include?(stage)
          enforce_outcome = enforce_clean_exit!(task, cfg, stage)
          # When CleanExit overwrites the runner's marker to
          # `:error reason=ensure_clean_on_exit_failed`, the stage's own
          # `result[:commit]` (e.g. "review_complete") is now stale —
          # `commands/run.rb#commit_after` would otherwise write a
          # misleading hive-state commit advertising a success that
          # didn't happen. Replace the commit action with the actual
          # outcome so the hive-state commit matches the on-disk marker.
          if enforce_outcome.is_a?(Hash) && enforce_outcome[:overwrote_marker]
            result = (result.is_a?(Hash) ? result : {}).merge(
              commit: "ensure_clean_on_exit_failed",
              status: :error
            )
          end
        end
        marker = Hive::Markers.current(task.state_file)
        emit_marker_event(task, stage, marker)
        Hive::Events.emit(
          task_folder: task.folder,
          slug: task.slug,
          stage: stage,
          event_type: :stage_exit,
          message: stage_exit_message(marker)
        )
        result
      rescue SystemExit => e
        emit_rescue_close(task, stage, "system_exit status=#{e.status}")
        raise
      rescue StandardError => e
        emit_rescue_close(task, stage, "#{e.class}: #{e.message}")
        raise
      end

      # Read `stages.ensure_clean_on_exit` (default true). Explicit
      # `false` opts the whole invariant out — useful for legacy projects
      # that haven't reconfigured `review.fix.auto_commit.scope_check`
      # and don't want stage-exit residue to fail loudly yet.
      def ensure_clean_on_exit_enabled?(cfg)
        return true unless cfg.is_a?(Hash)

        value = cfg.dig("stages", "ensure_clean_on_exit")
        value.nil? || value != false
      end

      # Markers whose presence means the runner intentionally paused for
      # operator action (4-execute mid-pass dirty-worktree pause,
      # 6-review wall-clock stale, etc.). The exit-invariant explicitly
      # does NOT touch the worktree on these — they ARE the
      # "operator-decide" semantic and the runner has typed-marker
      # context the generic invariant lacks (see plan §"Non-goals":
      # "Changing what the 4-execute stage does when it detects a
      # waiting dirty worktree mid-pass ... is not in scope").
      #
      # The list is narrowed to markers actually reachable on a
      # WORKTREE_OWNING_STAGES stage (4-execute / 6-review / 8-finalize):
      # the generic `:waiting` and `:manual_steering` markers are
      # written by `2-brainstorm` / `3-plan` agents, never on a
      # worktree-owning stage. Adding a new pause marker to a
      # worktree-owning stage requires a deliberate edit here.
      PAUSE_MARKERS = %i[execute_waiting review_waiting].freeze

      # CleanExit checks the worktree at `stage_exit`. On residue:
      #   - `:auto_committed` → log and fall through (the residue is
      #     committed; the stage marker the runner wrote stands).
      #   - `:scope_violation` / `:git_failed` → write
      #     `:error reason=ensure_clean_on_exit_failed`, BUT never
      #     downgrade an already-terminal `:error` (the wrapped runner's
      #     own error wins for diagnostic clarity).
      #
      # Returns a sentinel hash describing the outcome so the caller
      # (`with_stage_events`) can decide whether the stage's
      # `result[:commit]` is now stale:
      #   { status: :clean | :auto_committed | :scope_violation |
      #             :git_failed | :skipped,
      #     overwrote_marker: true | false }
      # `:skipped` covers PAUSE_MARKERS and missing-worktree no-ops; any
      # rescued StandardError returns nil so call sites keep their
      # historical "treat as no-op" behaviour.
      def enforce_clean_exit!(task, cfg, stage)
        worktree_path = read_worktree_path(task)
        return { status: :skipped, overwrote_marker: false } unless worktree_path && File.directory?(worktree_path)

        # The runner may have already paused intentionally — let that
        # marker stand and skip the invariant entirely. Without this,
        # 4-execute's `:execute_waiting reason=dirty_worktree` pause
        # would be overwritten by `:error reason=ensure_clean_on_exit_failed`
        # the moment the agent dropped an out-of-scope file.
        existing_marker = Hive::Markers.current(task.state_file)
        return { status: :skipped, overwrote_marker: false } if PAUSE_MARKERS.include?(existing_marker.name)

        result = Hive::Stages::CleanExit.run!(
          worktree_path: worktree_path,
          stage: stage,
          task: task,
          cfg: cfg,
          reason: :stage_exit
        )

        case result[:status]
        when :clean, :auto_committed
          log_clean_exit_event(task, stage, result)
          { status: result[:status], overwrote_marker: false }
        when :scope_violation, :git_failed
          overwrote = mark_clean_exit_failure(task, result, existing_marker)
          { status: result[:status], overwrote_marker: overwrote }
        else
          { status: result[:status], overwrote_marker: false }
        end
      rescue Hive::ConfigError => e
        # Misconfiguration (invalid sign_policy etc.) is not transient
        # I/O; the operator needs to see it. Mark `:error` so the
        # failure surfaces through the same recovery surface as a
        # scope-violation residue, instead of silently dropping into
        # the generic `rescue StandardError` warn-and-continue path.
        warn "[hive] ensure_clean_on_exit invalid config: #{e.message}"
        existing_marker = safe_current_marker(task)
        overwrote = mark_clean_exit_failure(
          task,
          { status: :git_failed,
            message: "invalid sign_policy config: #{e.message}" },
          existing_marker
        )
        { status: :git_failed, overwrote_marker: overwrote }
      rescue StandardError => e
        warn "[hive] ensure_clean_on_exit raised #{e.class}: #{e.message}; leaving marker untouched"
        nil
      end

      def safe_current_marker(task)
        Hive::Markers.current(task.state_file)
      rescue StandardError
        nil
      end

      def read_worktree_path(task)
        return nil unless task.respond_to?(:worktree_yml_path)
        return nil unless File.exist?(task.worktree_yml_path)

        pointer = Hive::Worktree.read_pointer(task.folder)
        pointer && pointer["path"]
      rescue StandardError
        nil
      end

      def log_clean_exit_event(task, stage, result)
        return unless result[:status] == :auto_committed

        Hive::Events.emit(
          task_folder: task.folder,
          slug: task.slug,
          stage: stage,
          event_type: :clean_exit_auto_committed,
          message: "head=#{result[:head]} paths=#{Array(result[:paths]).join(',')[0, 200]}"
        )
      rescue StandardError
        nil
      end

      def mark_clean_exit_failure(task, result, existing_marker = nil)
        existing_marker ||= safe_current_marker(task)
        return false if existing_marker && error_marker?(existing_marker.name)

        attrs = {
          reason: "ensure_clean_on_exit_failed",
          detail: result[:message].to_s[0, 200]
        }
        attrs[:residue_paths] = Array(result[:paths]).join(",")[0, 200] if result[:paths]
        Hive::Markers.set(task.state_file, :error, **attrs)
        true
      end

      # `error` + closing `stage_exit` pair so drill-down readers see a
      # balanced bracket on failure paths. Without the trailing stage_exit
      # an operator scanning events.jsonl would observe an open stage
      # bracket per raise — confusing in the TUI and breaks any future
      # consumer that depends on enter/exit symmetry.
      #
      # Body wrapped in its own rescue so a secondary failure here (e.g.
      # Hive::Markers.current on a corrupt state file feeding stage_label,
      # or Events.emit raising on a programmer bug) can never escape and
      # mask the original exception the caller is propagating.
      def emit_rescue_close(task, stage, error_message)
        stage ||= stage_label(task)
        Hive::Events.emit(
          task_folder: task.folder,
          slug: task.slug,
          stage: stage,
          event_type: :error,
          message: error_message
        )
        Hive::Events.emit(
          task_folder: task.folder,
          slug: task.slug,
          stage: stage,
          event_type: :stage_exit,
          message: "status=error #{error_message}"
        )
      rescue StandardError
        nil
      end

      def stage_label(task)
        "#{task.stage_index}-#{task.stage_name}"
      end

      # Stage runners that publish `round_waiting` / `round_complete`
      # events when their state-file marker lands on `:waiting` /
      # `:complete`. Adding a new stage that wants the round events
      # must add itself here. Kept on Base as a single registry so the
      # `emit_marker_event` allow-list can never drift away from the
      # stage-runner site that produces those markers.
      ROUND_EVENT_STAGES = %w[brainstorm plan].freeze

      def emit_marker_event(task, stage, marker)
        if ROUND_EVENT_STAGES.include?(task.stage_name)
          case marker.name
          when :waiting
            Hive::Events.emit(task_folder: task.folder, slug: task.slug, stage: stage,
                              event_type: :round_waiting, message: "status=waiting")
          when :complete
            Hive::Events.emit(task_folder: task.folder, slug: task.slug, stage: stage,
                              event_type: :round_complete, message: "status=complete")
          end
        end

        return unless error_marker?(marker.name)

        Hive::Events.emit(task_folder: task.folder, slug: task.slug, stage: stage,
                          event_type: :error, message: marker_event_message(marker))
      end

      def error_marker?(name)
        %i[error review_error review_ci_stale review_stale].include?(name)
      end

      def marker_event_message(marker)
        attrs = marker.attrs
        detail = attrs["reason"] || attrs["phase"] || attrs["attempts"] || attrs["pass"]
        return "#{marker.name} #{detail}" if detail

        marker.name.to_s
      end

      # Stage_exit message includes reason / phase / pass when present so
      # a drill-down reader scanning events.jsonl for "what closed this
      # stage" sees the actionable context, not just the marker name.
      # Falls back to the marker name alone when no relevant attrs landed.
      def stage_exit_message(marker)
        attrs = marker.attrs
        details = %w[phase reason pass].map { |key| attrs[key] && "#{key}=#{attrs[key]}" }.compact
        return "status=#{marker.name}" if details.empty?

        "status=#{marker.name} #{details.join(' ')}"
      end

      # Spawn an agent and return its result hash.
      #
      # Default profile is :claude so existing callers (4-execute /
      # brainstorm / plan / pr stages) keep their behavior unchanged when
      # they call this without a profile: kwarg.
      #
      # When the configured profile lacks add_dir_flag and the caller
      # passed add_dirs, log a warning to the task's log file so the user
      # can see that ADR-008's filesystem-isolation boundary is reduced
      # for this spawn (per ADR-018).
      def spawn_agent(task, prompt:, max_budget_usd:, timeout_sec:,
                      add_dirs: [], cwd: nil, log_label: nil,
                      profile: nil, expected_output: nil, status_mode: nil,
                      cfg: nil, permission_mode: nil, allowed_tools: nil,
                      disallowed_tools: nil)
        profile ||= Hive::AgentProfiles.lookup(:claude)
        # Translate preflight/version-check failures (e.g. Pi missing
        # ~/.pi/agent/auth.json mid-loop) into a typed :error envelope
        # so callers (Review.run!'s spawn_fix_agent etc.) write a
        # properly-attributed REVIEW_ERROR (`reason="agent_preflight_failed"`)
        # instead of letting the exception escape and land
        # `reason="runner_exception"`.
        begin
          profile.check_version!
          profile.preflight!
        rescue Hive::AgentError => e
          return { status: :error,
                   error_message: "preflight failed: #{e.message}" }
        end

        if !profile.add_dir_flag && Array(add_dirs).any?
          warn_isolation_reduced(task, profile, add_dirs)
        end

        cli_flags = []
        if cfg && profile.name == :claude
          permission_mode ||= Hive::Config.claude_permission_mode(cfg)
          cli_flags = Hive::Config.claude_cli_flags(cfg)
        end

        started_at = Time.now.utc.iso8601
        result = Hive::Agent.new(
          task: task,
          prompt: prompt,
          max_budget_usd: max_budget_usd,
          timeout_sec: timeout_sec,
          add_dirs: add_dirs,
          cwd: cwd,
          log_label: log_label,
          profile: profile,
          expected_output: expected_output,
          status_mode: status_mode,
          permission_mode: permission_mode,
          allowed_tools: allowed_tools,
          disallowed_tools: disallowed_tools,
          cli_flags: cli_flags
        ).run!
        record_usage(task, profile, result, started_at)
        result
      end

      def spawn_claude!(task, cfg, prompt:, max_budget_usd:, timeout_sec:,
                         session_name:, add_dirs: [], cwd: nil, log_label: nil,
                         profile: nil, expected_output: nil, status_mode: nil,
                         permission_mode: nil, allowed_tools: nil,
                         disallowed_tools: nil)
        require "hive/claude_launcher"

        profile ||= Hive::AgentProfiles.lookup(:claude, cfg: cfg)
        unless profile.name == :claude
          raise Hive::AgentError,
                "spawn_claude! only supports the claude profile; got #{profile.name.inspect}"
        end

        Hive::ClaudeLauncher.launch!(
          task: task,
          cfg: cfg,
          prompt: prompt,
          add_dirs: add_dirs,
          cwd: cwd || task.folder,
          max_budget_usd: max_budget_usd,
          timeout_sec: timeout_sec,
          log_label: log_label,
          session_name: session_name,
          status_mode: status_mode,
          expected_output: expected_output,
          profile: profile,
          permission_mode: permission_mode,
          allowed_tools: allowed_tools,
          disallowed_tools: disallowed_tools
        )
      end

      # Wrap a spawn_claude! call so that AgentErrors land on the
      # calling stage's own task.state_file with an attributed marker
      # rather than propagating uncaught through Plan.run! / OpenPr.run!
      # / Finalize.run! / Artifacts.run! / Execute.run_pass — none of
      # which carry their own `rescue Hive::AgentError`.
      #
      # tmux-unavailable errors are tagged `reason="tmux_unavailable"`
      # (existing contract, preserved). Every OTHER AgentError raised
      # by `ClaudeLauncher.launch!` — "tmux session … did not start",
      # "tmux session … already exists", "claude interactive prompt did
      # not become ready", "could not inspect claude tmux session",
      # etc. — used to escape as a generic crash via cli.rb, leaving a
      # stale AGENT_WORKING marker on disk. Now they land
      # `reason="claude_launch_failed"` so the operator sees the real
      # cause and AGENT_WORKING is replaced.
      #
      # The 6-review stage deliberately does NOT use this helper: its
      # sub-stage spawns share state with the main review task, and the
      # outer `Stages::Review.run!` rescue maps the same AgentError to
      # `:review_error reason="tmux_unavailable"` against the real task.
      # Routing through here would write the wrong marker shape onto the
      # synthetic-task state file (which points at the main task.md).
      def spawn_claude_with_tmux_marker!(task, cfg, **kwargs)
        spawn_claude!(task, cfg, **kwargs)
      rescue Hive::AgentError => e
        if Hive::Config.claude_mode(cfg) == :tmux &&
           Hive::ClaudeLauncher.tmux_unavailable_error?(e)
          warn "[hive] claude tmux mode is unavailable: #{e.message}"
          Hive::Markers.set(task.state_file, :error,
                            reason: "tmux_unavailable",
                            message: e.message)
          return { status: :error, error_message: e.message }
        end

        # Any other AgentError out of the launcher: surface the cause,
        # replace any stale AGENT_WORKING with an attributed :error so
        # `hive status` shows the failure state and the runner picks a
        # recoverable next step instead of treating the task as alive.
        warn "[hive] claude launch failed: #{e.message}"
        Hive::Markers.set(task.state_file, :error,
                          reason: "claude_launch_failed",
                          exception_class: e.class.name,
                          message: e.message)
        { status: :error, error_message: e.message }
      end

      class TemplateBindings
        def initialize(values = {})
          values.each do |k, v|
            instance_variable_set("@#{k}", v)
            self.class.send(:attr_reader, k) unless respond_to?(k)
          end
        end

        def binding_for_erb
          binding
        end
      end

      def warn_isolation_reduced(task, profile, add_dirs)
        # Reject non-Array add_dirs loudly instead of silently coercing via
        # Array() — a Hash or string here is an upstream type bug, not a
        # legitimate single-dir shorthand.
        unless add_dirs.is_a?(Array)
          raise ArgumentError,
                "spawn_agent expected add_dirs to be an Array; got #{add_dirs.class}"
        end

        message = "[hive] agent profile #{profile.name.inspect} has no add_dir_flag; " \
                  "ignoring add_dirs=#{add_dirs.inspect}. " \
                  "ADR-008 filesystem-isolation boundary is reduced for this spawn (see ADR-018)."
        # Best-effort log write; never blocks spawn.
        begin
          FileUtils.mkdir_p(task.log_dir)
          ts = Time.now.utc.iso8601
          File.open(File.join(task.log_dir, "isolation-warnings.log"), "a") do |f|
            f.puts "#{ts} #{message}"
          end
        rescue StandardError
          # If the log path can't be written, fall back to stderr — but
          # don't raise, since the warning is informational.
          warn message
        end
      end

      def record_usage(task, profile, result, started_at)
        usage = result && result[:usage]
        return unless usage

        Hive::UsageDb.record!(
          agent: profile.name.to_s,
          model: usage[:model] || result[:model],
          project_slug: usage_project_slug(task),
          task_slug: usage_task_slug(task),
          stage: usage_stage_label(task),
          started_at: started_at,
          ended_at: Time.now.utc.iso8601,
          input: usage[:input] || 0,
          output: usage[:output] || 0,
          cached: usage[:cached] || 0
        )
      rescue StandardError => e
        warn "[hive] usage record failed: #{e.message}"
      end

      def usage_project_slug(task)
        return task.project_name if task.respond_to?(:project_name)
        return File.basename(task.project_root.to_s) if task.respond_to?(:project_root) && task.project_root

        nil
      end

      def usage_task_slug(task)
        return task.slug if task.respond_to?(:slug)

        basename = File.basename(task.folder.to_s)
        basename.empty? ? nil : basename
      end

      def usage_stage_label(task)
        if task.respond_to?(:stage_index) && task.respond_to?(:stage_name) && task.stage_index
          return "#{task.stage_index}-#{task.stage_name}"
        end
        return task.stage_name.to_s if task.respond_to?(:stage_name) && !task.stage_name.to_s.empty?

        folder = task.respond_to?(:folder) ? task.folder.to_s : ""
        parent = File.basename(File.dirname(folder))
        parent.empty? ? nil : parent
      end
    end
  end
end
