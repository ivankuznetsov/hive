require "json"
require "hive/commands/approve"
require "hive/commands/run"
require "hive/markers"
require "hive/stages"
require "hive/task_resolver"
require "hive/workflows"
require "hive/task_action"

module Hive
  module Commands
    # Workflow verb dispatcher. Each of `brainstorm`, `plan`, `develop`,
    # `pr`, `archive` is a single Thor command that resolves a slug or
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
      def initialize(verb, target, project: nil, from: nil, json: false)
        @verb = verb
        @target = target
        @project_filter = project
        @from = from
        @json = json
      end

      def call
        do_call
      rescue Hive::Error => e
        emit_error_envelope(e) if @json
        raise
      rescue StandardError => e
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_error_envelope(wrapped) if @json
        raise wrapped
      end

      private

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
          raise Hive::WrongStage,
                "#{@verb} expects #{source_stage} or #{target_stage}, " \
                "but #{task.slug} is at #{current_stage}"
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
        raise Hive::WrongStage,
              "task #{task.slug} is at #{actual} but --from expected #{@from} " \
              "(idempotency check: a prior call may have already advanced this task)"
      end

      # Archive on a task already at 7-done with :complete is a no-op.
      # Without this guard, every `hive archive <slug>` invocation re-runs
      # the Done agent and writes a fresh `hive: 7-done/<slug> archived`
      # commit to hive/state.
      def archive_noop?(task, current_stage)
        return false unless @verb == "archive"
        return false unless current_stage == "7-done"

        Hive::Markers.current(task.state_file).name == :complete
      end

      def validate_marker!(task, config)
        return if config[:force_source]

        marker = Hive::Markers.current(task.state_file)
        return if terminal_marker?(marker)

        next_command = "hive #{@verb} #{task.slug} --from #{stage_dir(task)}"
        raise Hive::WrongStage,
              "#{@verb} cannot advance #{task.slug} from #{stage_dir(task)} while marker is :#{marker.name}; " \
              "finish the current stage first, then run `#{next_command}`"
      end

      # Markers whose presence means "this stage is done; the next verb
      # may advance the task". 5-review writes `:review_complete` as
      # its terminal marker (see `Hive::Stages::Review`'s phase
      # progression: REVIEW_COMPLETE | REVIEW_WAITING | REVIEW_*_STALE)
      # and `Hive::Commands::Run#json_next_action` already treats it as
      # an advance-eligible state alongside `:complete` and
      # `:execute_complete`. Without `:review_complete` here, `hive pr
      # --from 5-review` raised WrongStage on every otherwise-valid
      # post-review hand-off — the `hive tui`'s "Ready for PR" rows
      # depend on this whitelist matching TaskAction's classification.
      def terminal_marker?(marker)
        %i[complete execute_complete review_complete].include?(marker.name)
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
          force: config[:force_source],
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
          puts "hive: noop — #{task.slug} is already at 7-done"
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

      def emit_error_envelope(error)
        payload = Hive::Schemas::ErrorEnvelope.build(
          schema: "hive-stage-action",
          error: error,
          error_kind: error_kind_for(error),
          extras: { "verb" => @verb }
        )
        puts JSON.generate(payload)
      end

      def error_kind_for(error)
        case error
        when Hive::AmbiguousSlug then "ambiguous_slug"
        when Hive::DestinationCollision then "destination_collision"
        when Hive::FinalStageReached then "final_stage"
        when Hive::WrongStage then "wrong_stage"
        when Hive::RollbackFailed then "rollback_failed"
        when Hive::InvalidTaskPath then "invalid_task_path"
        else "error"
        end
      end

      def stage_dir(task)
        "#{task.stage_index}-#{task.stage_name}"
      end
    end
  end
end
