require "erb"
require "fileutils"
require "securerandom"
require "time"
require "hive/agent"
require "hive/agent_runtime"
require "hive/agent_profiles"
require "hive/config"
require "hive/events"
require "base64"
require "json"
require "hive/markers"
require "hive/model_routing"
require "hive/permission_scope"
require "hive/stages/clean_exit"
require "hive/usage_db"
require "hive/worktree"
require "hive/attempts/context"
require "hive/agent_observation"
require "hive/billing_evidence"
require "hive/context_provenance"
require "hive/task_activity"
require "hive/brainstorm_parser"
require "hive/task_workspace/bounded_reader"
require "hive/implementation_identity/store"

module Hive
  module Stages
    module Base
      DEFAULT_GENERIC_STAGE_TIMEOUT_SEC = 1800
      CONTROLLER_LAUNCH_ENV_KEYS = %w[
        HIVE_EVIDENCE_WRITE_ROOT HIVE_EVIDENCE_TASK_ROOT
        HIVE_EVIDENCE_SOURCE_ROOT HIVE_EVIDENCE_SOURCE_SHA
        HIVE_EVIDENCE_APP_PORT HIVE_EVIDENCE_BROWSER_ORIGIN
        HIVE_EVIDENCE_WEB_HIVE_HOME HIVE_EVIDENCE_CAPTURE_MAILBOX
      ].freeze
      DIRECT_PROVIDER_IDENTITIES = {
        claude: "anthropic", codex: "openai", grok: "xai"
      }.freeze

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
      def stage_profile(cfg, stage_name, explicit_agent: nil)
        if (context = Hive::Attempts::Context.current)&.explicit_routing?
          return Hive::AgentProfiles.lookup(context.adapter, cfg: cfg)
        end

        name = explicit_agent || cfg.dig(stage_name, "agent") || "claude"
        Hive::AgentProfiles.lookup(name, cfg: cfg)
      end

      def format_verified_skill_invocation(profile, skill, project_root:)
        invocation = profile.format_skill_invocation(skill)
        return invocation unless profile.name == :opencode

        status, evidence = profile.verify_skill(invocation, project_root: project_root)
        return invocation if status == :present

        raise Hive::AgentError,
              "OpenCode skill readiness failed for #{invocation}: #{evidence}"
      end

      # Production stage launches run inside a durable attempt. Direct unit
      # calls predating attempt supervision receive nil and retain their
      # explicit test profile seam; real launches always resolve and journal
      # implementation ownership before Process.spawn/tmux starts.
      def implementation_stage_identity(task, cfg, stage)
        return nil unless Hive::Attempts::Context.current

        Hive::ImplementationIdentity::Store.new(task: task, cfg: cfg).resolve_stage!(stage)
      end

      # Managed executable actors run from their task folder, but a yolo actor
      # may intentionally inspect or mutate the project that owns that task.
      # Include the project as explicit runner context only for managed
      # workflows: ordinary brainstorm/plan stages retain their deliberately
      # task-only add-dir boundary.
      def managed_actor_base_add_dirs(task)
        dirs = [ task.folder ]
        if task.respond_to?(:managed_workflow?) && task.managed_workflow?
          dirs.unshift(task.project_root)
        end
        dirs.uniq
      end

      # Durable routed identities intentionally persist provider-neutral
      # routing metadata instead of rendered argv. Materialize that metadata
      # through the selected profile at the last trusted seam before launch;
      # legacy identities continue to use their stored native argv unchanged.
      def implementation_launch_arguments(identity, profile)
        return { identity_arguments: nil, routing_arguments: nil } unless identity

        {
          identity_arguments: identity.native_arguments,
          routing_arguments: identity.routing_arguments(profile)
        }
      end

      # Resolve one non-durable built-in launch through the same closed,
      # provider-neutral routing domain as implementation identities. The
      # caller has already selected the profile; this helper can change only
      # model and effort, never provider. A nil return preserves the exact
      # legacy launch path when no route is active.
      def model_routing_arguments(cfg, stage, profile, current: {})
        cfg ||= {}
        models = cfg.fetch("models", Hive::ModelRouting::EMPTY_MODELS)
        return nil if models.empty?

        resolution = Hive::ModelRouting.resolve(
          models: models,
          stage: stage,
          current: current || Hive::ModelRouting::EMPTY_MODELS,
          legacy: legacy_model_routing_values(cfg, profile),
          provider: profile.name
        )
        return nil unless resolution.active?

        profile.routing_arguments(
          resolution,
          source: model_routing_source(cfg)
        )
      end

      # Build the complete model/effort kwargs for one non-durable spawn.
      #
      # `model_routing_arguments` intentionally returns nil when the project
      # has no top-level `models:` map: in that mode the per-stage values are
      # legacy/current controls, not routed controls. Callers used to pass
      # only that nil `routing_arguments` value, which silently discarded an
      # explicit `review.reviewers[].model`, `review.triage.model`, and other
      # stage-local pins. Pi then fell back to its unrelated global default
      # model while Hive labelled the spawn with the configured reviewer
      # name.
      #
      # Preserve the routing precedence when `models:` is active; otherwise
      # return the stage-local model/effort through spawn_agent's existing
      # legacy identity path. Provider selection remains owned by `profile`.
      def model_launch_arguments(cfg, stage, profile, current: {})
        normalized_current = model_routing_current(current)
        routing = model_routing_arguments(
          cfg, stage, profile, current: normalized_current
        )
        return { routing_arguments: routing } if routing

        {
          model: normalized_current[:model],
          effort: normalized_current[:effort]
        }.compact
      end

      def model_routing_current(block)
        return Hive::ModelRouting::EMPTY_MODELS unless block.is_a?(Hash)

        {
          model: block["model"] || block[:model],
          effort: block["effort"] || block[:effort]
        }.compact
      end

      # Generic workflow/council stages keep descriptor-level controls unless
      # their descriptor name is one of Hive's closed built-in identities.
      # This preserves arbitrary custom stage names while letting the generic
      # execution seam honor a built-in identity without inventing an open
      # `models:` namespace.
      def recognized_model_routing_arguments(cfg, stage, profile, current: {})
        return nil unless Hive::ModelRouting.known?(stage)

        model_routing_arguments(cfg, stage, profile, current: current)
      end

      def legacy_model_routing_values(cfg, profile)
        return Hive::ModelRouting::EMPTY_MODELS unless profile.name == :claude

        {
          model: cfg.dig("claude", "model"),
          effort: cfg.dig("claude", "effort")
        }.compact
      end
      private_class_method :legacy_model_routing_values

      def model_routing_source(cfg)
        root = cfg["project_root"].to_s
        return "project config" if root.empty?

        File.join(root, ".hive-state", "config.yml")
      end
      private_class_method :model_routing_source

      def stage_permission_scope(cfg, stage_name, task, profile,
                                 base_add_dirs: [ task.folder ],
                                 default_allowed_tools: nil,
                                 explicit_permission_spec: MISSING_EXPLICIT_PERMISSION_SPEC,
                                 managed_slot: nil,
                                 managed_context: nil,
                                 managed_outputs: [])
        if (context = Hive::Attempts::Context.current)&.explicit_routing?
          profile = Hive::AgentProfiles.lookup(context.adapter, cfg: cfg)
        end
        if task.respond_to?(:managed_workflow?) && task.managed_workflow?
          require "hive/workflow_package/runtime_policy"
          if explicit_permission_spec.equal?(MISSING_EXPLICIT_PERMISSION_SPEC)
            raise Hive::ConfigError, "managed executable actor #{managed_slot || stage_name} is missing exact permissions"
          end
          slot_id = managed_slot || "stages.#{stage_name}"
          context = managed_context || task.managed_runtime_context(slot_id)
          runtime_policy = Hive::WorkflowPackage::RuntimePolicy.compile_actor(
            explicit_permission_spec,
            task_folder: task.folder, profile: profile,
            package_root: context.fetch(:package_root), environment: context.fetch(:environment),
            base_add_dirs: base_add_dirs,
            managed_outputs: managed_outputs
          )
          values = {
            add_dirs: runtime_policy.directories,
            permission_mode: runtime_policy.permission_mode,
            allowed_tools: runtime_policy.allowed_tools,
            disallowed_tools: runtime_policy.disallowed_tools,
            runtime_policy: runtime_policy
          }
          if profile.name == :opencode
            values[:additional_read_roots] = runtime_policy.directories
            values[:additional_write_roots] = opencode_write_roots(
              profile, runtime_policy.allowed_tools, runtime_policy.directories,
              host_outputs: runtime_policy.host_outputs?
            )
            values[:opencode_edit_patterns] = opencode_edit_patterns(
              profile, runtime_policy.allowed_tools
            )
          end
          return adapt_opencode_scope!(values, profile, stage_name)
        end

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
          if profile.name == :opencode
            raise Hive::ConfigError,
                  "stage #{stage_name} must select read-only or scoped permissions for OpenCode"
          end
          return {
            add_dirs: base_dirs,
            permission_mode: nil,
            allowed_tools: default_allowed_tools_for_mode(cfg, profile, default_allowed_tools),
            disallowed_tools: nil
          }
        end

        values = {
          add_dirs: base_dirs + scope.add_dirs_extra,
          permission_mode: scope.permission_mode,
          allowed_tools: scope.allowed_tools,
          disallowed_tools: scope.disallowed_tools
        }
        if profile.name == :opencode
          directories = base_dirs + scope.add_dirs_extra
          values[:additional_read_roots] = directories
          values[:additional_write_roots] = opencode_write_roots(
            profile, scope.allowed_tools, directories
          )
          values[:opencode_edit_patterns] = opencode_edit_patterns(
            profile, scope.allowed_tools
          )
        end
        adapt_opencode_scope!(values, profile, stage_name)
      end

      # Prepare one actor launch from one managed snapshot, so its prompt and
      # permission scope cannot observe different configuration generations.
      def actor_prompt_and_scope(cfg, stage_name, task, profile, prompt:,
                                 managed_slot: "stages.#{stage_name}", **scope_kwargs)
        with_permission_config_error_marker(task) do
          context = task.managed_runtime_context(managed_slot) if
            task.respond_to?(:managed_workflow?) && task.managed_workflow?
          prompt = task.managed_prompt(managed_slot, prompt, context) if context
          scope = stage_permission_scope(
            cfg, stage_name, task, profile,
            managed_slot: managed_slot, managed_context: context, **scope_kwargs
          )
          prompt = scope[:runtime_policy].decorate_prompt(prompt) if
            scope[:runtime_policy]&.host_outputs?
          [ prompt, scope ]
        end
      end

      # The three tool-scoping kwargs every spawn site forwards from a
      # resolved-scope Hash to spawn_agent / spawn_claude!. Splat this
      # (`**Base.tool_scope_kwargs(scope)`)
      # instead of restating the triplet at each call so the keys can't drift
      # across the spawn sites. `scope` is the Hash stage_permission_scope
      # returns, NOT the PermissionScope::Scope struct.
      def tool_scope_kwargs(scope)
        kwargs = {
          permission_mode: scope.fetch(:permission_mode),
          allowed_tools: scope.fetch(:allowed_tools),
          disallowed_tools: scope.fetch(:disallowed_tools),
          additional_read_roots: scope.fetch(:additional_read_roots, []),
          additional_write_roots: scope.fetch(:additional_write_roots, []),
          opencode_edit_patterns: scope.fetch(:opencode_edit_patterns, [])
        }
        kwargs[:runtime_policy] = scope[:runtime_policy] if scope[:runtime_policy]
        kwargs
      end

      # Generic agent and council stages use the same state-file marker
      # vocabulary when naming their durable hive-state commits.
      def marker_commit_action(marker_name)
        case marker_name
        when :waiting then "round_waiting"
        when :complete then "complete"
        when :error then "error"
        when :none then nil
        else marker_name.to_s
        end
      end

      # The per-spec explicit-permission passthrough every reviewer
      # scope-building site needs: forward `spec["permissions"]` as
      # :explicit_permission_spec ONLY when the key is present, so an absent
      # key falls through to the project default (the MISSING sentinel) rather
      # than overriding it with nil. Returns {} when absent so callers can
      # splat it unconditionally into stage_permission_scope.
      def explicit_permission_kwargs(spec)
        spec.key?("permissions") ? { explicit_permission_spec: spec["permissions"] } : {}
      end

      # Single-agent stage variant of stage_permission_scope that attributes
      # the A8 runner-gate failure to the stage's own task marker.
      #
      # PermissionScope.resolve raises Hive::ConfigError when a non-yolo
      # scope lands on a runner that can't enforce tool scoping (codex / pi)
      # — or on any malformed spec that slips past load-time validation.
      # That raise is the FIRST line of every single-agent spawn helper
      # (plan / execute / open_pr / finalize / artifacts / brainstorm /
      # generic agent), none of which rescue it, so it would otherwise
      # propagate through with_stage_events uncaught and leave the stage's
      # prior marker (e.g. AGENT_WORKING) stale. The plan's U10-4 contract
      # requires an attributed :error marker, not a bare crash. Mirror
      # Review.run!'s ConfigError rescue: stamp an attributed :error on the
      # real task, then re-raise so the failure still surfaces loudly
      # (fail-closed) to the runner and test suite.
      #
      # Review sub-stages deliberately do NOT use this helper: their
      # synthetic-task spawns share state with the main review task and the
      # outer Review.run! rescue maps the same ConfigError to :review_error
      # against the real task (see review.rb).
      def stage_permission_scope_or_mark!(cfg, stage_name, task, profile, **kwargs)
        with_permission_config_error_marker(task) do
          stage_permission_scope(cfg, stage_name, task, profile, **kwargs)
        end
      end

      def with_permission_config_error_marker(task)
        yield
      rescue Hive::ConfigError => e
        Hive::Markers.set(task.state_file, :error,
                          reason: "permission_config_error",
                          message: e.message.to_s[0, 200])
        raise
      end

      def default_allowed_tools_for_mode(cfg, profile, default_allowed_tools)
        return nil unless default_allowed_tools
        return nil unless profile.name == :claude
        return nil unless cfg && Hive::Config.claude_mode(cfg) == :tmux

        default_allowed_tools
      end

      def adapt_opencode_scope!(values, profile, stage_name)
        return values unless profile.name == :opencode

        granted = Array(values[:allowed_tools]).flat_map do |rule|
          Hive::PermissionScope.granted_tool_names(rule)
        end
        if granted.include?("Bash")
          raise Hive::ConfigError,
                "stage #{stage_name} OpenCode permissions cannot grant unrestricted Bash"
        end
        writable = Array(values[:additional_write_roots]).any?
        values.merge(
          permission_mode: writable ? "workspace-write" : "read-only",
          allowed_tools: nil,
          disallowed_tools: nil
        )
      end
      private_class_method :adapt_opencode_scope!

      def opencode_write_roots(profile, allowed_tools, directories,
                               host_outputs: false)
        return [] unless profile.name == :opencode
        return [] if host_outputs

        granted = Array(allowed_tools).flat_map do |rule|
          Hive::PermissionScope.granted_tool_names(rule)
        end
        return [] if (granted & Hive::PermissionScope::FILE_EDIT_TOOLS).empty?

        qualified = Array(allowed_tools).filter_map do |rule|
          match = Hive::PermissionScope::TOOL_RULE_PATTERN.match(rule.to_s)
          next unless match && match[:tool] == "Edit" && match[:specifier]

          match[:specifier].sub(%r{\A//}, "/").delete_suffix("/**")
        end
        return Array(directories) if qualified.empty?

        Array(directories).select do |directory|
          expanded = File.expand_path(directory)
          qualified.any? do |root|
            expanded == root || expanded.start_with?(root + File::SEPARATOR) ||
              root.start_with?(expanded + File::SEPARATOR)
          end
        end
      end
      private_class_method :opencode_write_roots

      def opencode_edit_patterns(profile, allowed_tools)
        return [] unless profile.name == :opencode

        Array(allowed_tools).filter_map do |rule|
          match = Hive::PermissionScope::TOOL_RULE_PATTERN.match(rule.to_s)
          next unless match && match[:tool] == "Edit" && match[:specifier]

          match[:specifier].sub(%r{\A//}, "/")
        end.uniq
      end
      private_class_method :opencode_edit_patterns

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
        record_stage_activity(task, stage, "entered")
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
          if enforce_outcome.is_a?(Hash) && enforce_outcome[:status] == :auto_committed
            result = reconcile_auto_committed_execute_residue(
              task, cfg, stage, result
            )
          end
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
        record_stage_activity(task, stage, "exited", marker: marker)
        record_waiting_questions(task, stage, marker)
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

      # Execute deliberately records ERROR reason=dirty_worktree before the
      # generic stage-exit invariant runs. When that invariant safely commits
      # the residue, leaving the error marker behind would make a clean,
      # descendant implementation require a second harness pass merely to
      # observe the commit. Reuse Execute's guarded recovery boundary so only
      # an owned 4-execute worktree on the expected branch can be promoted.
      def reconcile_auto_committed_execute_residue(task, cfg, stage, result)
        return result unless stage == "4-execute" # coding-scoped: execute residue recovery

        marker = Hive::Markers.current(task.state_file)
        return result unless marker.name == :error && marker.attrs["reason"] == "dirty_worktree"
        return result if Hive::Stages::Execute.research_execution?(task)

        worktree_path = read_worktree_path(task)
        return result unless worktree_path

        Hive::Stages::Execute.recover_committed_residue!(
          task, cfg, worktree_path
        )
      rescue Hive::WorktreeError => e
        warn "[hive] execute residue auto-commit could not complete the stage: #{e.message}"
        result
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
      #   - `:scope_violation` / `:safety_violation` / `:git_failed` → write
      #     `:error reason=ensure_clean_on_exit_failed`, BUT never
      #     downgrade an already-terminal `:error` (the wrapped runner's
      #     own error wins for diagnostic clarity).
      #
      # Returns a sentinel hash describing the outcome so the caller
      # (`with_stage_events`) can decide whether the stage's
      # `result[:commit]` is now stale:
      #   { status: :clean | :auto_committed | :scope_violation | :safety_violation |
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
        when :scope_violation, :safety_violation, :git_failed
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

      # Open-PR and finalize share the same hard precondition: execute must
      # have left an ownership-proven pointer to this task's registered
      # worktree. A path that merely exists is not sufficient: automatic retry
      # must never establish an agent-tampered sibling pointer as the baseline.
      def worktree_pointer_or_exit(task)
        # Lightweight stage unit doubles predate the ownership API and do not
        # carry enough project metadata to prove registration. Runtime tasks
        # are always Hive::Task instances and therefore always take the strict
        # branch below.
        unless task.is_a?(Hive::Task)
          pointer = Hive::Worktree.read_pointer(task.folder)
          unless pointer && pointer["path"] && File.directory?(pointer["path"])
            warn "hive: worktree pointer at #{pointer && pointer['path']} no longer exists; recreate or move task back to 4-execute"
            exit 1
          end
          return pointer
        end

        root = Hive::Worktree.canonical_root(task.project_root)
        Hive::Worktree.read_owned_pointer(
          task.folder,
          project_root: task.project_root,
          slug: task.slug,
          expected_root: root
        )
      rescue Hive::WorktreeError => e
        warn "hive: worktree ownership validation failed: #{e.message}; recreate or move task back to 4-execute"
        exit 1
      end

      def log_clean_exit_event(task, stage, result)
        return unless result[:status] == :auto_committed

        paths = Hive::Events.clean_exit_paths(result[:paths])
        Hive::Events.emit(
          task_folder: task.folder,
          slug: task.slug,
          stage: stage,
          event_type: :clean_exit_auto_committed,
          message: "head=#{result[:head]} paths=#{paths.join(',')[0, 200]}",
          data: Hive::Events.clean_exit_data(
            head: result[:head], reason: "stage_exit", paths: paths
          )
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
        if result[:paths]
          paths = Array(result[:paths]).first(Hive::Events::MAX_EVENT_PATHS).map(&:to_s)
          attrs[:residue_paths] = paths.join(",")[0, 200]
          attrs[:residue_paths_b64] = Base64.strict_encode64(JSON.generate(paths))
        end
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
        record_stage_activity(task, stage, "failed", error: error_message)
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

      def record_stage_activity(task, stage, transition, marker: nil, error: nil)
        payload = {
          "transition" => transition,
          "marker" => marker&.name&.to_s,
          "error_class" => error.to_s.split(":", 2).first.to_s.byteslice(0, 128)
        }
        context = Hive::Attempts::Context.current
        return false unless context

        suffix = transition == "entered" ? "enter" : "exit"
        record_task_activity(
          task, kind: "stage_transition",
          operation_id: "stage:#{context.attempt_id}:#{suffix}",
          correlation_id: context.attempt_id,
          reason: "stage #{transition}", source: "stage_service", payload: payload,
          stage: stage
        )
      end

      def record_task_activity(task, kind:, operation_id:, reason:, source:, payload: {},
                               evidence: [], correlation_id: nil, stage: nil,
                               occurred_at: nil)
        context = Hive::Attempts::Context.current
        return false unless context && context.attempt_id && context.task_generation

        activity = Hive::TaskActivity.for_context(task, context: context)
        return false unless activity

        activity.record(
          kind: kind, operation_id: operation_id,
          correlation_id: correlation_id,
          reason: reason, source: source,
          payload: payload, evidence: evidence,
          occurred_at: occurred_at
        )
        true
      rescue Hive::TaskActivity::Error, SystemCallError, IOError
        false
      end

      def record_waiting_questions(task, stage, marker)
        return false unless task.respond_to?(:stage_name) && task.stage_name == "brainstorm"
        return false unless marker.name == :waiting

        context = Hive::Attempts::Context.current
        return false unless context&.attempt_id

        reference = File.basename(task.state_file)
        read = Hive::TaskWorkspace::BoundedReader.new(root: task.folder).read(
          reference, max_bytes: 512 * 1024
        )
        return false if read.truncated || read.binary

        questions = Hive::BrainstormParser.parse_text(read.content)
        questions.each_with_index do |question, index|
          fingerprint = Hive::BrainstormParser.question_fingerprint(question.text)
          record_task_activity(
            task, kind: "question_asked",
            operation_id: "question:#{context.attempt_id}:#{fingerprint}",
            correlation_id: "question:#{fingerprint}",
            reason: "brainstorm question asked", source: "stage_service",
            stage: stage,
            payload: {
              "question_id" => "Q#{index + 1}", "round" => question.round,
              "question_number" => question.n,
              "question_fingerprint" => fingerprint
            },
            evidence: [ { "evidence_ref" => reference, "kind" => "question_slot" } ]
          )
        end
        true
      rescue Hive::TaskWorkspace::SourceError, Hive::Error, SystemCallError, IOError
        false
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

      # A marker holds only the most recent failure: the next run overwrites
      # it, taking its diagnostic with it. The reason code alone does not
      # distinguish causes — one 7-artifacts task failed 25 times under
      # `outcome_evidence_invalid` for three unrelated reasons, and only the
      # last was still recoverable. events.jsonl is append-only, so carrying
      # the diagnostic here preserves each failure's cause for later reading.
      MAX_EVENT_DIAGNOSTIC_BYTES = 200

      def marker_event_message(marker)
        attrs = marker.attrs
        detail = attrs["reason"] || attrs["phase"] || attrs["attempts"] || attrs["pass"]
        # Stages disagree on the key: the artifacts stage writes `diagnostic`,
        # the council writes `message`. Reading only one of them left every
        # council_failed in the event log as a bare reason code with no way to
        # tell a crashed reviewer from a failed revise.
        diagnostic = (attrs["diagnostic"] || attrs["message"]).to_s.strip
        parts = [ marker.name.to_s ]
        parts << detail if detail
        unless diagnostic.empty?
          bounded = diagnostic.byteslice(0, MAX_EVENT_DIAGNOSTIC_BYTES).to_s.scrub
          parts << "diagnostic=#{bounded}"
        end
        parts.join(" ")
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
                      permission_arguments: nil,
                      disallowed_tools: nil, cli_flags: nil,
                      model: nil, effort: nil, identity_arguments: nil, runtime_policy: nil,
                      routing_resolution: nil, routing_arguments: nil,
                      additional_read_roots: [], additional_write_roots: [],
                      opencode_edit_patterns: [],
                      implementation_stage: nil,
                      defer_implementation_observation: false,
                      resource_guards: nil, agent_custody: nil,
                      isolate_environment: false, launch_environment: nil)
        launch_environment = (launch_environment || {}).to_h.transform_keys(&:to_s)
        unknown_launch_keys = launch_environment.keys - CONTROLLER_LAUNCH_ENV_KEYS
        unless unknown_launch_keys.empty? && launch_environment.values.all? { |value| value.is_a?(String) }
          raise ArgumentError, "controller launch environment is invalid"
        end
        context = Hive::Attempts::Context.current
        launch_binding = nil
        provider_route = nil
        if context&.explicit_routing?
          profile = Hive::AgentProfiles.lookup(context.adapter, cfg: cfg)
          launch_binding = Hive::AgentProfiles::LaunchBindings.resolve(
            adapter: context.adapter,
            binding_id: context.launch_binding_id
          )
          routing_arguments = admitted_routing_arguments(context, profile)
          routing_resolution = nil
          identity_arguments = nil
          model = nil
          effort = nil
          cli_flags = []
          provider_route = context.admitted_route
        end
        profile ||= Hive::AgentProfiles.lookup(:claude)
        prompt = Hive::ContextProvenance.decorate_prompt(
          task: task, prompt: prompt, context: context
        )
        if routing_resolution && routing_arguments
          raise ArgumentError, "pass routing_resolution or routing_arguments, not both"
        end
        routing_arguments ||= profile.routing_arguments(routing_resolution) if routing_resolution
        profile.validate_routing_arguments!(routing_arguments) if routing_arguments
        # Translate preflight/version-check failures (e.g. Pi missing
        # ~/.pi/agent/auth.json mid-loop) into a typed :error envelope
        # so callers (Review.run!'s spawn_fix_agent etc.) write a
        # properly-attributed REVIEW_ERROR (`reason="agent_preflight_failed"`)
        # instead of letting the exception escape and land
        # `reason="runner_exception"`.
        begin
          Hive::AgentRuntime.prepare!(profile, launch_binding: launch_binding)
        rescue Hive::AgentError => e
          if context&.explicit_routing?
            return {
              status: :error,
              error_reason: "provider_route_preflight_failed",
              error_message: "preflight failed for admitted provider account #{context.provider_account_id}"
            }
          end
          return { status: :error,
                   error_message: "preflight failed: #{e.message}" }
        end

        if profile.name != :opencode && !profile.add_dir_flag && Array(add_dirs).any?
          warn_isolation_reduced(task, profile, add_dirs)
        end
        if max_budget_usd && !profile.budget_flag
          warn_budget_unenforced(task, profile, max_budget_usd)
        end

        # `cli_flags: nil` means "no explicit flags — derive model/effort
        # (and permission_mode) from cfg". `cli_flags: []` means "explicitly
        # none — do NOT derive" (a caller, e.g. the headless ClaudeLauncher
        # path, already assembled the flags and must win over cfg; commit
        # 01841e12). Keying derivation on nil-vs-[] keeps those two intents
        # distinct rather than collapsing both to "empty".
        derive_flags_from_cfg =
          cli_flags.nil? && identity_arguments.nil? && routing_arguments.nil?
        cli_flags ||= []
        launch_arguments = nil
        if routing_arguments.nil? && identity_arguments.nil? && (model || effort)
          if profile.model_argument_builder
            concrete_model = model || profile.concrete_default_model(
              cfg: cfg, project_root: cfg && cfg["project_root"]
            )
            launch_arguments = profile.identity_arguments(
              model: concrete_model, effort: effort
            )
            identity_arguments = launch_arguments.native_arguments
          else
            # Old-shape custom profiles predate normalized identity
            # capabilities. Preserve their historical launch behavior for
            # this legacy call form; implementation-owning stages pass an
            # already-resolved identity_arguments array and never use this
            # compatibility path.
            warn_model_effort_dropped(task, profile, model: model, effort: effort)
            identity_arguments = []
          end
        elsif derive_flags_from_cfg && cfg && profile.name == :claude
          permission_mode ||= Hive::Config.claude_permission_mode(cfg)
          cli_flags = Hive::Config.claude_cli_flags(cfg, model: model, effort: effort)
        end

        started_at = Time.now.utc.iso8601
        effective_status_mode = runtime_policy&.host_outputs? ? :exit_code_only : status_mode
        requested_identity = requested_model(
          context, routing_arguments, launch_arguments, model
        )
        requested_provider, requested_model_identity = execution_identity(
          profile, requested_identity
        )
        billing_route, billing_evidence_source = billing_launch_evidence(
          context, profile
        )
        observation = session_observation(
          task: task, context: context, profile: profile,
          role: log_label || task.stage_name,
          requested_provider: requested_provider,
          requested_model: requested_model_identity,
          requested_effort: requested_effort(context, routing_arguments, launch_arguments, effort),
          billing_route: billing_route,
          billing_evidence_source: billing_evidence_source,
          timeout_sec: timeout_sec,
          guards: runtime_resource_guards(
            resource_guards, profile: profile, max_budget_usd: max_budget_usd,
            timeout_sec: timeout_sec
          )
        )
        result = nil
        start_session_observation!(observation)
        begin
          result = run_with_agent_custody(agent_custody) do
            agent_result = Hive::Agent.new(
              task: task,
              prompt: prompt,
              max_budget_usd: max_budget_usd,
              timeout_sec: timeout_sec,
              add_dirs: add_dirs,
              cwd: cwd,
              log_label: log_label,
              profile: profile,
              expected_output: expected_output,
              status_mode: effective_status_mode,
              permission_mode: permission_mode,
              permission_arguments: permission_arguments,
              allowed_tools: allowed_tools,
              disallowed_tools: disallowed_tools,
              cli_flags: cli_flags,
              identity_arguments: identity_arguments || [],
              launch_arguments: launch_arguments,
              runtime_policy: runtime_policy,
              routing_arguments: routing_arguments,
              launch_environment: (launch_binding&.environment || {}).merge(launch_environment),
              provider_route: provider_route,
              additional_read_roots: additional_read_roots,
              additional_write_roots: additional_write_roots,
              opencode_edit_patterns: opencode_edit_patterns,
              isolate_environment: isolate_environment
            ).run!
            agent_result[:hive_observation_id] = observation.session_id if
              agent_result.is_a?(Hash) && profile.name == :opencode
            enrich_execution_identity!(agent_result, profile)
            if agent_result[:status] == :ok && runtime_policy&.host_outputs?
              begin
                runtime_policy.materialize_outputs!(agent_result)
              rescue Hive::ConfigError => e
                agent_result[:status] = :error
                agent_result[:error_reason] = "managed_output_invalid"
                agent_result[:error_message] = e.message
              end
            end
            agent_result
          end
          if profile.name == :opencode && implementation_stage &&
             !defer_implementation_observation && agent_custody_safe_after?(agent_custody)
            record_deferred_opencode_observation(
              task, cfg, implementation_stage, result
            )
          end
          record_usage(
            task, profile, result, started_at,
            context: context, session_id: observation.session_id
          )
          if context && agent_custody_safe_after?(agent_custody)
            Hive::ContextProvenance.promote_agent_receipt(
              task: task, context: context
            )
          end
          if result[:provider_signal]
            unless context.publish_provider_signal(result.fetch(:provider_signal))
              raise Hive::ProviderRouteFailed, "admitted provider route failed without durable evidence delivery"
            end
            raise Hive::ProviderRouteFailed, "admitted provider route failed"
          end
          result
        ensure
          if agent_custody_safe_after?(agent_custody)
            observation.finish!(result || {}, exception: $!)
          end
        end
      ensure
        runtime_policy&.cleanup!
      end

      def admitted_routing_arguments(context, profile)
        stage = context.intended_stage.to_s.sub(/\A\d+-/, "").tr("-", "_")
        provenance = Hive::ModelRouting::FIELDS.to_h do |field|
          value = context.public_send(field)
          kind = value.nil? ? :absent : :exact
          [
            field,
            Hive::ModelRouting::Provenance.new(
              kind: kind,
              key: value.nil? ? nil : "admitted_route"
            )
          ]
        end
        profile.routing_arguments(
          Hive::ModelRouting::Resolution.new(
            stage: stage,
            provider: profile.name,
            model: context.model,
            effort: context.effort,
            provenance: provenance
          ),
          source: "durable admitted route"
        )
      end

      def stage_resource_limits(cfg, stage)
        budget = Hive::Config.stage_resource_limit_resolution(
          cfg, "budget_usd", stage.name, descriptor_default: stage.budget_usd
        )
        timeout = Hive::Config.stage_resource_limit_resolution(
          cfg, "timeout_sec", stage.name,
          descriptor_default: stage.timeout_sec,
          fallback: DEFAULT_GENERIC_STAGE_TIMEOUT_SEC
        )
        {
          max_budget_usd: budget.value,
          timeout_sec: timeout.value,
          resource_guards: [ budget.to_h, timeout.to_h ]
        }
      end

      def spawn_claude!(task, cfg, prompt:, max_budget_usd:, timeout_sec:,
                         session_name:, add_dirs: [], cwd: nil, log_label: nil,
                         profile: nil, expected_output: nil, status_mode: nil,
                         permission_mode: nil, allowed_tools: nil,
                         disallowed_tools: nil, mcp_config_path: nil,
                         strict_mcp_config: false, identity_arguments: nil,
                         routing_arguments: nil, runtime_policy: nil,
                         implementation_stage: nil,
                         additional_read_roots: [], additional_write_roots: [],
                         opencode_edit_patterns: [],
                         resource_guards: nil, agent_custody: nil)
        require "hive/claude_launcher"

        context = Hive::Attempts::Context.current
        if context&.explicit_routing? && context.adapter != "claude"
          return spawn_agent(
            task,
            prompt: prompt,
            max_budget_usd: max_budget_usd,
            timeout_sec: timeout_sec,
            add_dirs: add_dirs,
            cwd: cwd,
            log_label: log_label,
            profile: Hive::AgentProfiles.lookup(context.adapter, cfg: cfg),
            expected_output: expected_output,
            status_mode: status_mode,
            cfg: cfg,
            permission_mode: permission_mode,
            allowed_tools: allowed_tools,
            disallowed_tools: disallowed_tools,
            identity_arguments: identity_arguments,
            routing_arguments: routing_arguments,
            runtime_policy: runtime_policy,
            implementation_stage: implementation_stage,
            additional_read_roots: additional_read_roots,
            additional_write_roots: additional_write_roots,
            opencode_edit_patterns: opencode_edit_patterns,
            resource_guards: resource_guards,
            agent_custody: agent_custody
          )
        end

        profile = Hive::AgentProfiles.lookup(:claude, cfg: cfg) if context&.explicit_routing?
        profile ||= Hive::AgentProfiles.lookup(:claude, cfg: cfg)
        unless profile.name == :claude
          raise Hive::AgentError,
                "spawn_claude! only supports the claude profile; got #{profile.name.inspect}"
        end

        headless = context&.explicit_routing? || Hive::Config.claude_mode(cfg) == :headless
        if headless
          return Hive::ClaudeLauncher.launch!(
            task: task, cfg: cfg, prompt: prompt, add_dirs: add_dirs,
            cwd: cwd || task.folder, max_budget_usd: max_budget_usd,
            timeout_sec: timeout_sec, log_label: log_label,
            session_name: session_name, status_mode: status_mode,
            expected_output: expected_output, profile: profile,
            permission_mode: permission_mode, allowed_tools: allowed_tools,
            disallowed_tools: disallowed_tools, mcp_config_path: mcp_config_path,
            strict_mcp_config: strict_mcp_config,
            identity_arguments: identity_arguments,
            routing_arguments: routing_arguments, runtime_policy: runtime_policy,
            additional_read_roots: additional_read_roots,
            additional_write_roots: additional_write_roots,
            opencode_edit_patterns: opencode_edit_patterns,
            resource_guards: resource_guards, agent_custody: agent_custody
          )
        end

        prompt = Hive::ContextProvenance.decorate_prompt(
          task: task, prompt: prompt, context: context
        )
        observation = session_observation(
          task: task, context: context, profile: profile,
          role: log_label || task.stage_name,
          requested_model: requested_model(context, routing_arguments, nil, nil),
          requested_effort: requested_effort(context, routing_arguments, nil, nil),
          timeout_sec: timeout_sec,
          guards: runtime_resource_guards(
            resource_guards, profile: profile, max_budget_usd: max_budget_usd,
            timeout_sec: timeout_sec
          )
        )
        result = nil
        started_at = Time.now.utc.iso8601
        start_session_observation!(observation)
        begin
          result = run_with_agent_custody(agent_custody) do
            Hive::ClaudeLauncher.launch!(
              task: task, cfg: cfg, prompt: prompt, add_dirs: add_dirs,
              cwd: cwd || task.folder, max_budget_usd: max_budget_usd,
              timeout_sec: timeout_sec, log_label: log_label,
              session_name: session_name, status_mode: status_mode,
              expected_output: expected_output, profile: profile,
              permission_mode: permission_mode, allowed_tools: allowed_tools,
              disallowed_tools: disallowed_tools, mcp_config_path: mcp_config_path,
              strict_mcp_config: strict_mcp_config,
              identity_arguments: identity_arguments,
              routing_arguments: routing_arguments, runtime_policy: runtime_policy,
              additional_read_roots: additional_read_roots,
              additional_write_roots: additional_write_roots,
              opencode_edit_patterns: opencode_edit_patterns
            )
          end
          record_usage(
            task, profile, result, started_at,
            context: context, session_id: observation.session_id
          )
          if context && agent_custody_safe_after?(agent_custody)
            Hive::ContextProvenance.promote_agent_receipt(
              task: task, context: context
            )
          end
          result
        ensure
          if agent_custody_safe_after?(agent_custody)
            observation.finish!(result || {}, exception: $!)
          end
        end
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
        raise if e.is_a?(Hive::ProviderRouteFailed)

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

      # Artifact custody belongs around the untrusted provider execution, not
      # around controller-authored session, usage, or context receipts. The
      # caller supplies a callable that captures and validates its stage-local
      # protected-file manifest while this block runs.
      def run_with_agent_custody(agent_custody)
        return yield unless agent_custody
        raise ArgumentError, "agent_custody must respond to call" unless agent_custody.respond_to?(:call)

        agent_custody.call { yield }
      end

      def agent_custody_safe_after?(agent_custody)
        !agent_custody.respond_to?(:safe_after?) || agent_custody.safe_after?
      end

      class TemplateBindings
        def initialize(values = {})
          values.each { |k, v| instance_variable_set("@#{k}", v) }
        end

        def binding_for_erb
          binding
        end

        # Prompt templates are shared across stages, but each binding sets only
        # the keys its stage supplies. A template that references a key this
        # instance wasn't given -- e.g. the generic runner's `instruction_body`
        # on a coding binding -- must read as nil, not raise. Resolving every
        # bare name to its ivar (nil when unset) also makes rendering
        # independent of construction order: the previous design lazily defined
        # an `attr_reader` on the SHARED class only when some instance passed
        # that key, so a render against a binding that omitted the key crashed
        # with NameError unless a key-bearing instance happened to be built
        # first -- a seed-dependent flake across the suite.
        def method_missing(name, *args)
          return super unless args.empty? && name.match?(/\A\w+\z/)

          instance_variable_get("@#{name}")
        end

        def respond_to_missing?(name, _include_private = false)
          name.match?(/\A\w+\z/) || super
        end
      end

      def warn_model_effort_dropped(task, profile, model:, effort:)
        fields = { "model" => model, "effort" => effort }.compact
        message = "[hive] agent profile #{profile.name.inspect} does not honor per-stage " \
                  "#{fields.map { |key, value| "#{key}=#{value.inspect}" }.join(', ')}; " \
                  "the profile has no normalized model capability, so they are ignored for this spawn."
        write_spawn_warning(task, "config-warnings.log", message)
      end

      def warn_budget_unenforced(task, profile, max_budget_usd)
        message = "[hive] agent profile #{profile.name.inspect} has no native budget flag; " \
                  "budget_usd=#{max_budget_usd} is not enforced for this spawn. " \
                  "The stage timeout remains enforced."
        write_spawn_warning(task, "config-warnings.log", message)
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
        write_spawn_warning(task, "isolation-warnings.log", message)
      end

      def write_spawn_warning(task, filename, message)
        # Warnings must never block an otherwise valid spawn.
        begin
          FileUtils.mkdir_p(task.log_dir)
          ts = Time.now.utc.iso8601
          File.open(File.join(task.log_dir, filename), "a") do |f|
            f.puts "#{ts} #{message}"
          end
        rescue StandardError
          warn message
        end
      end

      def session_observation(task:, context:, profile:, role:, requested_model:,
                              requested_effort:, timeout_sec:, guards:,
                              requested_provider: nil, billing_route: "unknown",
                              billing_evidence_source: "unavailable")
        Hive::AgentObservation.new(
          task: task, context: context, session_id: SecureRandom.uuid,
          role: role, provider: profile.name.to_s,
          requested_provider: requested_provider,
          requested_model: requested_model, requested_effort: requested_effort,
          billing_route: billing_route,
          billing_evidence_source: billing_evidence_source,
          timeout_sec: timeout_sec, guards: guards
        )
      end

      def billing_launch_evidence(context, profile)
        if context&.explicit_routing?
          return [ context.billing_route, context.billing_evidence_source ]
        end

        Hive::BillingEvidence.for_profile(profile)
      end

      def execution_identity(profile, model)
        value = model.to_s
        profile_name = profile.name.to_sym
        if %i[opencode pi].include?(profile_name) && value.include?("/")
          return value.split("/", 2)
        end

        [ DIRECT_PROVIDER_IDENTITIES[profile_name], value.empty? ? nil : value ]
      end

      def enrich_execution_identity!(result, profile)
        return result unless result.is_a?(Hash)

        route = result[:actual_opencode_route]
        model = route || result[:model] || result.dig(:usage, :model)
        provider, actual_model = execution_identity(profile, model)
        result[:actual_provider] ||= provider
        result[:actual_model] ||= actual_model
        result[:execution_identity_source] ||=
          if route
            "sanitized_export"
          elsif model
            DIRECT_PROVIDER_IDENTITIES.key?(profile.name.to_sym) ?
              "provider_usage_event_and_profile_contract" : "provider_usage_event"
          else
            "unavailable"
          end
        result
      end

      def start_session_observation!(observation)
        return true if observation.start!
        return true unless observation.available?

        raise Hive::AgentError, "failed to record durable agent session start"
      end

      def requested_model(context, routing_arguments, launch_arguments, fallback)
        return context.model if context&.explicit_routing?

        routing_arguments&.model || launch_arguments&.model || fallback
      end

      def requested_effort(context, routing_arguments, launch_arguments, fallback)
        return context.effort if context&.explicit_routing?

        routing_arguments&.effort || launch_arguments&.requested_effort || fallback
      end

      def runtime_resource_guards(resolutions, profile:, max_budget_usd:, timeout_sec:)
        indexed = Array(resolutions).to_h do |resolution|
          row = resolution.to_h.transform_keys(&:to_s)
          [ row["field"], row ]
        end
        budget = indexed["budget_usd"] || {
          "value" => max_budget_usd, "source" => "caller", "scope" => "session"
        }
        timeout = indexed["timeout_sec"] || {
          "value" => timeout_sec, "source" => "caller", "scope" => "session"
        }
        billing = profile.billing_semantics.to_s
        budget_kind = billing == "api_billed" ?
          "monetary_api_cap" : "budget_equivalent_guard"
        [
          {
            "kind" => budget_kind, "unit" => "usd", "scope" => "session",
            "source" => budget.fetch("source", "unknown"),
            "enforcement" => profile.budget_flag ? "provider_cli" : "unenforced",
            "billing_semantics" => billing,
            "configured" => budget["value"], "observed" => nil
          },
          {
            "kind" => "timeout", "unit" => "seconds", "scope" => "session",
            "source" => timeout.fetch("source", "unknown"),
            "enforcement" => "controller", "billing_semantics" => "not_applicable",
            "configured" => timeout["value"], "observed" => nil
          }
        ]
      end

      def record_usage(task, profile, result, started_at, context: nil, session_id: nil)
        usage = result && result[:usage]
        return unless usage

        billing_route, billing_evidence_source = billing_launch_evidence(context, profile)
        Hive::UsageDb.record!(
          agent: profile.name.to_s,
          harness: profile.name.to_s,
          model: usage[:model] || result[:model],
          project_slug: usage_project_slug(task),
          task_slug: usage_task_slug(task),
          stage: usage_stage_label(task),
          started_at: started_at,
          ended_at: Time.now.utc.iso8601,
          input: usage[:input],
          output: usage[:output],
          cached: usage[:cached],
          cache_read: usage[:cache_read],
          cache_write: usage[:cache_write],
          reasoning: usage[:reasoning],
          input_includes_cache_read: usage[:input_includes_cache_read],
          input_includes_cache_write: usage[:input_includes_cache_write],
          output_includes_reasoning: usage[:output_includes_reasoning],
          provider_reported_cost:
            usage[:provider_reported_cost].nil? ? usage[:cost] : usage[:provider_reported_cost],
          cost: usage[:cost],
          requested_route: result[:requested_opencode_route],
          actual_route: result[:actual_opencode_route],
          actual_provider: result[:actual_provider],
          actual_model: result[:actual_model],
          billing_route: billing_route,
          billing_evidence_source: billing_evidence_source,
          attempt_id: context&.attempt_id,
          session_id: context ? session_id : nil,
          task_generation: context&.task_generation,
          source: context ? "runtime_receipt" : nil
        )
      rescue StandardError => e
        warn "[hive] usage record failed: #{e.message}"
      end

      def record_opencode_observation(task, cfg, stage, result)
        normalized_usage = result[:normalized_outcome]&.usage || result[:usage]
        Hive::ImplementationIdentity::Store.new(task: task, cfg: cfg).observe_opencode!(
          stage: stage,
          requested_route: result.fetch(:requested_opencode_route),
          actual_route: result[:actual_opencode_route],
          resolution_status: result.fetch(:route_resolution_status),
          outcome_kind: result.fetch(:normalized_outcome_kind),
          usage: normalized_usage,
          observation_id: result[:hive_observation_id]
        )
      end

      # Implementation stages protect their journal/projection files while an
      # agent is running. They defer this controller-owned append until after
      # that custody check so valid observed-route evidence cannot be mistaken
      # for agent tampering.
      def record_deferred_opencode_observation(task, cfg, stage, result)
        return result unless Hive::Attempts::Context.current
        return result unless result&.key?(:requested_opencode_route)

        record_opencode_observation(task, cfg, stage, result)
        result
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
