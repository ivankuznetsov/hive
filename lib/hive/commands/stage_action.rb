require "json"
require "hive/commands/approve"
require "hive/commands/run"
require "hive/gh"
require "hive/markers"
require "hive/stages"
require "hive/task_resolver"
require "hive/workflows"
require "hive/task_action"
require "hive/attempts/context"
require "hive/attempts/command_dispatch"
require "hive/conditions/transition_guard"

module Hive
  module Commands
    # Workflow verb dispatcher. Each workflow command resolves a slug or
    # folder, then either:
    #   - runs the target stage's agent if the task is already at the
    #     verb's target stage,
    #   - promotes (mv via Approve) from the verb's source stage to its
    #     target, then runs the target's agent,
    #   - no-ops if the task is already at the terminal stage with the
    #     terminal marker (archive only).
    #
    # `--from` doubles as an idempotency assertion. When set, the resolver
    # narrows the slug search to that stage; if the task isn't there, we
    # re-resolve without the filter and raise `WrongStage` with the actual
    # stage rather than a "no task folder" message.
    #
    # In `--json` mode the inner Approve and Run are quieted and a single
    # `hive-stage-action` envelope is emitted at the end.
    class StageAction
      include Hive::Schemas::EnvelopeEmitter
      include Hive::Attempts::CommandDispatch

      def initialize(verb, target, project: nil, from: nil, json: false,
                     recover_merged_error_reason: nil, durable: false,
                     attempt_entrypoint: nil)
        @verb = verb
        @target = target
        @project_filter = project
        @from = from
        @json = json
        @recover_merged_error_reason = recover_merged_error_reason
        @durable = durable
        @attempt_entrypoint = attempt_entrypoint
      end

      def call
        call_with_envelope do
          @durable && !Hive::Attempts::Context.active? ? dispatch_durable : do_call
        end
      end

      def envelope_schema
        "hive-stage-action"
      end

      def envelope_extras
        { "verb" => @verb }
      end

      def envelope_error_kind(error)
        error_kind_for(error)
      end

      private

      def durable_intended_stage(_task)
        Hive::Workflows.for_verb(@verb).fetch(:target)
      end

      def durable_worker_argv(task)
        argv = [ "hive", @verb, task.folder ]
        argv.concat([ "--from", @from ]) if @from
        argv << "--json" if @json
        if @recover_merged_error_reason
          argv.concat([ "--recover-merged-error-reason", @recover_merged_error_reason ])
        end
        argv
      end

      def do_call
        config = Hive::Workflows.for_verb(@verb)
        task = resolve_task
        current_stage = stage_dir(task)
        target_stage = config.fetch(:target)
        source_stage = config.fetch(:source)

        return emit_archive_noop(task) if archive_noop?(task, current_stage)

        if current_stage == target_stage
          run_at(task.folder)
          return emit_phase(task, "ran")
        end

        unless current_stage == source_stage
          raise Hive::WrongStage.new(
            "#{@verb} expects #{source_stage} or #{target_stage}, " \
            "but #{task.slug} is at #{current_stage}",
            current_stage: current_stage,
            target_stage: target_stage
          )
        end

        validate_marker!(task, config)
        new_folder = File.join(task.hive_state_path, "stages", target_stage, task.slug)
        promote(task, target_stage, current_stage, config)
        run_at(new_folder)
        emit_phase(Hive::Task.new(new_folder), "promoted_and_ran")
      end

      def resolve_task
        Hive::TaskResolver.new(@target, project_filter: @project_filter, stage_filter: @from).resolve
      rescue Hive::InvalidTaskPath
        raise unless @from

        # --from is an idempotency assertion. If the task isn't at the
        # asserted stage, fall back to a stage-unfiltered resolve so we
        # can surface the actual stage in a WrongStage (4) instead of
        # bubbling the resolver's "no task folder" (64). Mirrors the
        # pattern in Hive::Commands::Approve#resolve_task.
        task = Hive::TaskResolver.new(@target, project_filter: @project_filter).resolve
        actual = stage_dir(task)
        raise Hive::WrongStage.new(
          "task #{task.slug} is at #{actual} but --from expected #{@from} " \
          "(idempotency check: a prior call may have already advanced this task)",
          current_stage: actual,
          target_stage: @from
        )
      end

      # Archive on a task already at the terminal stage with :complete is a
      # no-op. Without this guard, every `hive archive <slug>` invocation
      # re-runs the Done agent and writes a fresh `hive: <terminal>/<slug>
      # archived` commit to hive/state. Stage name derived from the registry
      # so a future renumber doesn't silently disable the guard.
      def archive_noop?(task, current_stage)
        return false unless @verb == "archive"
        return false unless current_stage == Hive::Stages::DIRS.last

        Hive::Markers.current(task.state_file).name == :complete
      end

      def validate_marker!(task, config)
        return if config[:force_source]

        marker = Hive::Markers.current(task.state_file)
        Hive::Conditions::TransitionGuard.validate!(task, force: config[:force_source])
        return if terminal_marker?(marker)
        return if archive_merged_error_recovery_marker?(task, marker, config)

        next_command = "hive #{@verb} #{task.slug} --from #{stage_dir(task)}"
        raise Hive::WrongStage.new(
          "#{@verb} cannot advance #{task.slug} from #{stage_dir(task)} while marker is :#{marker.name}; " \
          "finish the current stage first, then run `#{next_command}`",
          current_stage: stage_dir(task),
          target_stage: config.fetch(:target)
        )
      end

      # See `Hive::Markers::TERMINAL_MARKER_NAMES` for the canonical
      # list and the cross-layer drift history. Single source of
      # truth — previously this list was hand-duplicated here,
      # creating the `:review_complete` gap that `hive tui`'s
      # "Ready for PR" rows tripped on every dispatch.
      def terminal_marker?(marker)
        Hive::Markers::TERMINAL_MARKER_NAMES.include?(marker.name)
      end

      def archive_merged_error_recovery_marker?(task, marker, config)
        return false unless @verb == "archive"
        return false unless stage_dir(task) == config.fetch(:source)
        return false unless marker.name == :error

        reason = @recover_merged_error_reason.to_s
        return false if reason.empty?

        return false unless marker.attrs.to_h.fetch("reason", nil).to_s == reason

        pr_url = Hive::Gh.pr_frontmatter(task.state_file)["pr_url"].to_s
        return false if pr_url.empty?

        Hive::Gh.pr_state(pr_url) == "MERGED"
      end

      # Inner Approve and Run are silent when the verb is in --json mode;
      # StageAction owns the unified envelope. In text mode they emit
      # their own prose because that output is intended for humans.
      def promote(task, target_stage, current_stage, config)
        Hive::Commands::Approve.new(
          task.folder,
          to: target_stage,
          from: current_stage,
          project: @project_filter,
          force: config[:force_source] || archive_merged_error_recovery_marker?(
            task,
            Hive::Markers.current(task.state_file),
            config
          ),
          json: false,
          quiet: @json
        ).call
      end

      def run_at(folder)
        Hive::Commands::Run.new(
          folder,
          project: @project_filter,
          json: false,
          quiet: @json
        ).call
      end

      # ── Reporting ───────────────────────────────────────────────────────

      def emit_phase(task, phase)
        return unless @json

        puts JSON.generate(success_payload(task, phase))
      end

      def emit_archive_noop(task)
        marker = Hive::Markers.current(task.state_file)
        if @json
          puts JSON.generate(success_payload(task, "noop",
                                             noop: true,
                                             reason: "already_archived",
                                             marker: marker))
        else
          puts "hive: noop — #{task.slug} is already at #{Hive::Stages::DIRS.last}"
        end
      end

      def success_payload(task, phase, noop: false, reason: nil, marker: nil)
        marker ||= Hive::Markers.current(task.state_file)
        config = Hive::Workflows.for_verb(@verb)
        action = Hive::TaskAction.for(task, marker)
        payload = {
          "schema" => "hive-stage-action",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-stage-action"),
          "ok" => true,
          "verb" => @verb,
          "phase" => phase,
          "noop" => noop,
          "slug" => task.slug,
          "from_stage_dir" => config.fetch(:source),
          "to_stage_dir" => config.fetch(:target),
          "task_folder" => task.folder,
          "marker_after" => marker.name.to_s,
          "next_action" => action.payload
        }
        payload["reason"] = reason if reason
        payload
      end

      def error_kind_for(error)
        Hive::Commands::Approve.error_kind_for(error)
      end

      def stage_dir(task)
        "#{task.stage_index}-#{task.stage_name}"
      end
    end
  end
end
