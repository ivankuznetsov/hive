require "hive/config"
require "hive/workflows"
require "hive/workflows/project"
require "hive/bot/notification_builders"

module Hive
  module Bot
    module Handlers
      # Single source of truth for operator retry intents. Every recovery
      # surface emits one generation-fenced `hive retry manual` request; this
      # module never clears markers, selects a delay, or reruns a stage.
      module RecoverySequence
        # Builds a full recovery Result when the status projection supplied a
        # current generation. Legacy/stale callbacks without that fence are
        # rejected and must be refreshed.
        def self.build(project:, slug:, stage:, marker:, match_attr:, result_class:, clear_keyboard:,
                       attrs: nil, workflow: nil, generation: nil)
          if generation.nil? || generation.to_s !~ /\A\d+\z/
            return result_class.new(
              action: :reply,
              text: "Retry state changed or is unavailable. Refresh status and try again."
            )
          end

          result_class.new(
            action: :dispatch_commands,
            project: project,
            slug: slug,
            commands: retry_commands(project: project, slug: slug, stage: stage,
                                     marker: marker, match_attr: match_attr, workflow: workflow,
                                     generation: generation),
            alert_reset: alert_reset(project, slug, stage, marker, match_attr),
            clear_keyboard: clear_keyboard
          )
        end

        def self.manual_only?(marker, attrs = nil)
          Hive::Bot::NotificationBuilders.manual_only?(marker: marker, attrs: attrs)
        end

        def self.manual_only_text(marker, attrs)
          Hive::Bot::NotificationBuilders.manual_only_reply(marker: marker, attrs: attrs)
        end

        # Inline keyboard callback_data carries `key=value` pairs via
        # `recovery_match_attr`, comma-separated when more than one is
        # encoded (e.g. `marker_id=abc,reason=ensure_clean_on_exit_failed`
        # — both tokens are needed so `manual_only?` can route on
        # `reason` while `marker_id` remains the race-safe clear
        # guard). Split each pair on the first `=` so a value like
        # `foo=bar=baz` keeps the trailing `=baz` intact.
        def self.attrs_from_match_attr(match_attr)
          raw = match_attr.to_s
          return nil unless raw.include?("=")

          attrs = {}
          raw.split(",").each do |pair|
            next unless pair.include?("=")

            key, value = pair.split("=", 2)
            key = key.to_s.strip
            attrs[key] = value unless key.empty?
          end
          attrs.empty? ? nil : attrs
        end

        def self.retry_verb_for_stage(stage, workflow: nil, project: nil)
          stage = stage.to_s
          # A non-coding workflow has one universal re-run verb: `hive run`
          # (the generic stage runner). Routes here when the caller carries
          # the row's workflow (slash /autofix, web recover, and the inline
          # Autofix button now that its callback_data threads the id). When
          # the workflow is nil/coding the coding verb table applies unchanged
          # (an unknown/empty stage still yields nil → "No retry verb").
          unless Hive::Workflows.coding_id?(workflow)
            # The terminal stage has no agent to re-run — offering `hive run`
            # there would dispatch `hive run --stage <terminal>` and raise
            # StageError. Guard it the way the coding path guards `9-done` below.
            return nil if generic_terminal_stage?(stage, workflow, project: project)

            # A non-:agent middle stage (inert/marker) likewise has no agent
            # runner — `Stages::Resolver.resolve` raises StageError for any
            # kind != :agent — so `hive run` there would queue a command that
            # always fails. Only the generic re-run verb's :agent stages can run.
            return nil if generic_non_agent_stage?(stage, workflow, project: project)

            return "run"
          end
          return nil if stage == "9-done" # coding-scoped: coding retry verbs have no terminal retry

          Hive::Workflows.verb_arriving_at(stage) || {
            "5-review" => "review", # not-a-stage-ref: defensive fallback, reached only when verb_arriving_at returns nil (legacy/renamed dirs)
            "6-pr" => "pr" # not-a-stage-ref: defensive fallback, reached only when verb_arriving_at returns nil (legacy/renamed dirs)
          }[stage]
        end

        # True when `stage` is the terminal (last) stage of a registered
        # non-coding workflow — the generic analog of the coding `9-done`
        # guard. A custom descriptor is registered only in ITS project's
        # overlay, so the row's project must be loaded before the lookup (the
        # bot process never loads project overlays on its own; the web process
        # may have a different one active). An unregistered/unloadable workflow
        # can't be introspected, so it conservatively reports false and the
        # caller falls back to offering `hive run`.
        def self.generic_terminal_stage?(stage, workflow, project: nil)
          descriptor = resolve_descriptor(workflow, project: project)
          return false unless descriptor

          last = descriptor.stages.last
          !last.nil? && last.dir == stage
        end

        # True when `stage` resolves to a NON-:agent stage (inert/marker) of a
        # registered non-coding workflow — the kinds with no agent runner
        # (`Stages::Resolver.resolve` raises StageError for kind != :agent), so
        # offering `hive run` would queue a command that always fails. Loads the
        # row's project overlay first (see generic_terminal_stage?). An
        # unregistered or unresolvable stage returns false so the caller keeps
        # its conservative "offer hive run" fallback.
        def self.generic_non_agent_stage?(stage, workflow, project: nil)
          descriptor = resolve_descriptor(workflow, project: project)
          return false unless descriptor

          found = descriptor.stage_for_dir(stage)
          !found.nil? && found.kind != :agent
        end

        # Resolve the row's workflow descriptor, loading the project's overlay
        # under Project::LOCK first so a project-authored descriptor (registered
        # only in that overlay) is reachable. The project NAME is mapped to its
        # root via the registry; a nil/unknown project skips the load and falls
        # back to whatever is active (the conservative path for callers that
        # carry no project). Returns nil — not raising — for an unknown workflow
        # so callers degrade to the "offer hive run" fallback.
        def self.resolve_descriptor(workflow, project: nil)
          Hive::Workflows::Project.synchronize do
            load_project_overlay(project)
            Hive::Workflows::Registry.fetch(workflow.to_s.to_sym)
          end
        rescue Hive::Workflows::UnknownWorkflow
          nil
        end

        def self.load_project_overlay(project_name)
          return if project_name.nil? || project_name.to_s.empty?

          match = Hive::Config.registered_projects.find { |p| p["name"] == project_name.to_s }
          Hive::Workflows::Project.load!(match["path"]) if match
        end

        # Diagnostic marker/stage/workflow inputs are deliberately ignored:
        # policy belongs to RetryCoordinator and the generation is the only
        # authorization context this producer carries.
        def self.retry_commands(project:, slug:, stage:, marker:, match_attr: nil, workflow: nil,
                                generation: nil)
          return [] unless generation.to_s.match?(/\A\d+\z/)

          [ [ "hive", "retry", "manual", slug, "--project", project,
              "--generation", generation.to_s, "--json" ] ]
        end

        def self.alert_reset(project, slug, stage, marker = nil, match_attr = nil)
          payload = { project: project, slug: slug, stage: stage }
          payload[:marker] = marker if marker && !marker.to_s.empty?
          payload[:match_attr] = match_attr if match_attr && !match_attr.to_s.empty?
          payload
        end
      end
    end
  end
end
