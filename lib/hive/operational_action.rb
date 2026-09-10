require "digest"
require "time"
require "hive/recovery/api"
require "hive/task_projection"
require "hive/workflow_package/canonical_json"
require "hive/task_closure"
require "hive/terminal_outcome"
require "hive/patrol_fix"

module Hive
  # Closed, non-shell recommendations emitted by the operational status
  # projector. An observation token is a freshness assertion, not an
  # authorization credential: execution still resolves the task again and
  # revalidates the same fields while the mutation command owns its lock.
  class OperationalAction
    ACTION_ID = "workflow.advance".freeze
    RETRY_ACTION_ID = "workflow.retry".freeze
    CLOSURE_ACTION_ID = "workflow.close_with_evidence".freeze
    PATROL_FIX_PUBLICATION_REWORK_ACTION_ID = "patrol_fix.rework_publication".freeze
    EXECUTABLE_ACTION_IDS = [
      ACTION_ID, RETRY_ACTION_ID, PATROL_FIX_PUBLICATION_REWORK_ACTION_ID
    ].freeze
    RISK_CLASS = "routine_idempotent".freeze

    SAFE_TASK_ACTIONS = %w[
      ready_to_brainstorm
      ready_to_plan
      ready_to_develop
      outcome_evidence_rework
      ready_to_open_pr
      ready_for_review
      ready_to_artifacts
      ready_to_finalize
      ready_to_archive
      ready_to_advance
      ready_to_run
    ].freeze

    TOKEN_FIELDS = %w[
      project slug folder workflow stage marker attrs mtime action
      condition_task_generation commit_generation current_attempt
      action_receipt_id
    ].freeze

    STAGE_ACTIONS = {
      "ready_to_brainstorm" => "brainstorm",
      "ready_to_plan" => "plan",
      "ready_to_develop" => "develop",
      "ready_to_open_pr" => "open-pr",
      "ready_for_review" => "review",
      "ready_to_artifacts" => "artifacts",
      "ready_to_finalize" => "finalize",
      "ready_to_archive" => "archive"
    }.freeze

    class << self
      def descriptor(project:, row:)
        action_id = action_id_for(row)
        return nil unless action_id

        {
          "action_id" => action_id,
          "target" => "#{project}:#{row.fetch('slug')}",
          "observation_token" => token(project: project, row: row),
          "risk_class" => RISK_CLASS,
          "confirmation_required" => false,
          "provenance" => {
            "source" => "hive-operational-status",
            "task_action" => row.fetch("action")
          }
        }
      end

      # This is an advertisement only. Executor deliberately does not include
      # CLOSURE_ACTION_ID in EXECUTABLE_ACTION_IDS, so an observation token can never
      # become closure authorization. Operators must use TaskClosure's
      # preview/confirm flow through an authenticated channel.
      def closure_descriptor(project:, row:)
        return nil if row["action"] == "archived"

        {
          "action_id" => CLOSURE_ACTION_ID,
          "target" => "#{project}:#{row.fetch('slug')}",
          "risk_class" => "operator_attested",
          "confirmation_required" => true,
          "supported_reasons" => Hive::TaskClosure::REASONS,
          "provenance" => {
            "source" => "hive-operational-status",
            "task_action" => row.fetch("action")
          }
        }
      end

      def safe?(row)
        SAFE_TASK_ACTIONS.include?(row["action"]) &&
          row["blocked"] != true && row["held"].nil? &&
          row["marker"] != "manual_steering"
      end

      def recoverable?(row)
        Hive::Recovery::API.recoverable_marker?(row["marker"]) &&
          !Hive::TaskProjection.history_invalid_row?(row) &&
          !Hive::TerminalOutcome.outcome_evidence_rework?(row["attrs"] || {}) &&
          row.dig("attrs", "reason").to_s != "invalid_task" &&
          !Hive::Recovery.intervention_required?(
            marker: row["marker"], attrs: row["attrs"] || {}, folder: row["folder"]
          ) &&
          row["marker"] != "manual_steering"
      end

      def action_id_for(row)
        if row["action"] == Hive::Schemas::TaskActionKind::PATROL_FIX_PUBLICATION_BLOCKED &&
           row["workflow"] == Hive::PatrolFix::WORKFLOW_ID.to_s && row["marker"] == "none" &&
           !row["action_receipt_id"].to_s.empty?
          return PATROL_FIX_PUBLICATION_REWORK_ACTION_ID
        end
        return RETRY_ACTION_ID if recoverable?(row)
        return ACTION_ID if safe?(row)

        nil
      end

      def token(project:, row:)
        if recoverable?(row)
          return Hive::Recovery::API.observation_token(
            row.merge(
              "project" => project,
              "state_file_mtime" => row["observation_mtime"] || row["mtime"],
              "marker_attrs" => row["attrs"],
              "attempt_id" => row["attempt_id"] || row["current_attempt"]
            )
          )
        end

        fields = TOKEN_FIELDS.to_h do |field|
          value = if field == "project"
            project
          elsif field == "mtime"
            row["observation_mtime"] || row["mtime"]
          else
            row[field]
          end
          [ field, value ]
        end
        ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(fields))
      end

      def observed_row(task, project:)
        require "hive/config"
        require "hive/markers"
        require "hive/task_action"
        require "hive/task_projection/reader"

        marker = if task.workflow.controller?
          Hive::Markers::State.new(name: :none, attrs: {}, raw: nil)
        else
          Hive::Markers.current(task.state_file)
        end
        bounded = Hive::TaskProjection::Reader.new(
          task_folder: task.folder, task: task
        ).read_routine(marker: marker)
        if bounded.current?
          projection = bounded.projection
          action_marker = marker
        else
          attrs = if bounded.state == "invalid"
            Hive::TaskProjection.invalid_journal_marker_attrs(bounded: bounded)
          else
            Hive::TaskProjection.unavailable_journal_marker_attrs(bounded: bounded)
          end
          action_marker = Hive::Markers::State.new(name: :error, attrs: attrs, raw: nil)
          projection = Hive::TaskProjection.project(records: [], marker: action_marker)
        end
        config = Hive::Config.load(task.project_root)
        action = Hive::TaskAction.for(
          task, action_marker, projection: projection, config: config, project_name: project
        )
        projection_data = projection.to_h
        {
          "project" => project,
          "slug" => task.slug,
          "folder" => task.folder,
          "state_file" => task.state_file,
          "workflow" => task.workflow.id.to_s,
          "stage" => "#{task.stage_index}-#{task.stage_name}",
          "marker" => action_marker.name.to_s,
          "attrs" => action_marker.attrs,
          "task_history_invalid" => bounded.state == "invalid",
          "mtime" => observation_mtime(task),
          "action" => action.key,
          "action_receipt_id" => action.respond_to?(:patrol_fix) ?
            action.patrol_fix&.dig("outcome", "receipt_id") : nil,
          "condition_task_generation" => projection_data.dig("identity", "task_generation"),
          "commit_generation" => projection_data.dig("identity", "commit_generation"),
          "current_attempt" => projection_data.dig("identity", "attempt_id"),
          "attempt_id" => projection_data.dig("identity", "attempt_id"),
          "task_generation" => projection_data.dig("identity", "task_generation"),
          "live_task_lock" => false,
          "blocked" => false,
          "held" => nil
        }
      end

      def descriptor_for_task(task, project:)
        descriptor(project: project, row: observed_row(task, project: project))
      end

      def assert_current!(task, project:, action_id:, target:, observation_token:)
        current = descriptor_for_task(task, project: project)
        unless current && current.fetch("action_id") == action_id &&
               current.fetch("target") == target &&
               secure_compare(current.fetch("observation_token"), observation_token)
          raise Hive::StaleOperationalObservation,
                "task changed or the recommendation is no longer routine; take a fresh operational snapshot"
        end

        current
      end

      def observation_mtime_source(task)
        if task.workflow.controller?
          return task.meta_yml_path if File.exist?(task.meta_yml_path)
          return task.folder
        end
        return task.state_file if File.exist?(task.state_file)
        return task.meta_yml_path if File.exist?(task.meta_yml_path)

        task.folder
      end

      private

      def observation_mtime(task)
        mtime = File.mtime(observation_mtime_source(task))
        mtime.utc.iso8601(6)
      end

      def secure_compare(left, right)
        right = right.to_s
        return false unless left.bytesize == right.bytesize

        left.bytes.zip(right.bytes).reduce(0) { |difference, (a, b)| difference | (a ^ b) }.zero?
      end
    end

    # Executes only the closed routine action above. The caller-supplied
    # values select no command arguments beyond the registered action ID and
    # exact project/task identity; stage, verb, and guards are recomputed.
    class Executor
      def initialize(recovery_writer: Hive::Recovery::API)
        @recovery_writer = recovery_writer
      end

      def execute(action_id:, target:, observation_token:)
        validate_action_id!(action_id)
        project_name, slug = parse_target(target)
        project = registered_project(project_name)
        task = resolve_task(slug, project_name)
        observed = OperationalAction.observed_row(task, project: project_name)
        OperationalAction.assert_current!(
          task,
          project: project_name,
          action_id: action_id,
          target: target,
          observation_token: observation_token
        )
        if action_id == OperationalAction::PATROL_FIX_PUBLICATION_REWORK_ACTION_ID
          execute_publication_rework(
            task, project_name: project_name, target: target,
            observation_token: observation_token
          )
          return result_for(project_name, slug)
        end
        if action_id == OperationalAction::RETRY_ACTION_ID
          receipt = @recovery_writer.recover!(
            row: observed,
            project: project_name,
            requestor: "action",
            observation_token: observation_token
          )
          return recovery_result(observed, receipt)
        end

        guard = lambda do |locked_task|
          OperationalAction.assert_current!(
            locked_task,
            project: project_name,
            action_id: action_id,
            target: target,
            observation_token: observation_token
          )
        end

        Dir.chdir(project.fetch("path")) do
          dispatch(task, observed, project_name, guard)
        end
        result_for(project_name, slug)
      end

      private

      def validate_action_id!(action_id)
        return if OperationalAction::EXECUTABLE_ACTION_IDS.include?(action_id)

        raise Hive::OperationalActionUsageError,
              "unknown operational action #{action_id.inspect}; take a fresh operational snapshot"
      end

      def parse_target(target)
        project, slug = target.to_s.split(":", 2)
        if project.to_s.empty? || slug.to_s.empty? || slug.include?(File::SEPARATOR)
          raise Hive::OperationalActionUsageError,
                "TARGET must be the exact project:slug emitted by operational status"
        end

        [ project, slug ]
      end

      def registered_project(name)
        require "hive/config"
        Hive::Config.registered_projects.find { |project| project["name"] == name } ||
          raise(Hive::OperationalActionUsageError, "unknown registered project #{name.inspect}")
      end

      def resolve_task(slug, project_name)
        require "hive/task_resolver"
        Hive::TaskResolver.new(slug, project_filter: project_name).resolve
      rescue Hive::AmbiguousSlug
        raise
      rescue Hive::InvalidTaskPath => e
        raise Hive::StaleOperationalObservation, e.message
      end

      def dispatch(task, observed, project_name, guard)
        action = observed.fetch("action")
        if (verb = OperationalAction::STAGE_ACTIONS[action])
          dispatch_stage_action(verb, task, project_name, observed.fetch("stage"), guard)
        elsif action == Hive::Schemas::TaskActionKind::OUTCOME_EVIDENCE_REWORK
          dispatch_outcome_evidence_rework(task, project_name, observed)
        elsif action == "ready_to_run"
          dispatch_run(task, project_name, observed.fetch("stage"), guard)
        elsif action == "ready_to_advance"
          dispatch_approve(task, project_name, observed, guard)
        else
          raise Hive::StaleOperationalObservation,
                "the current task state has no confirmation-free operational action"
        end
      end

      def execute_publication_rework(task, project_name:, target:, observation_token:)
        require "hive/lock"
        require "hive/patrol_fix/receipt_store"
        require "hive/patrol_fix/stage_transition"
        require "hive/patrol_fix/transition"

        OperationalAction.assert_current!(
          task, project: project_name,
          action_id: OperationalAction::PATROL_FIX_PUBLICATION_REWORK_ACTION_ID,
          target: target, observation_token: observation_token
        )
        Hive::PatrolFix::StageTransition.with_lock(task) do
          Hive::Lock.with_task_lock(task.folder, slug: task.slug, stage: task.stage_name) do
            lock = Hive::Lock.read_task_lock(task.folder)
            unless lock && lock["lock_id"]
              raise Hive::PatrolFix::Transition::InvalidTransition,
                    "publication rework task lock ownership could not be verified"
            end
            OperationalAction.assert_current!(
              task, project: project_name,
              action_id: OperationalAction::PATROL_FIX_PUBLICATION_REWORK_ACTION_ID,
              target: target, observation_token: observation_token
            )
            manifest = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read
            receipt = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).read_all.find do |row|
              row["kind"] == "publication_block" && row["stage"] == "publish" &&
                row["task"] == manifest["task"] &&
                row["evidence_revision"] == manifest["evidence_revision"]
            end
            unless receipt
              raise Hive::StaleOperationalObservation,
                    "publication block receipt changed; take a fresh operational snapshot"
            end
            OperationalAction.assert_current!(
              task, project: project_name,
              action_id: OperationalAction::PATROL_FIX_PUBLICATION_REWORK_ACTION_ID,
              target: target, observation_token: observation_token
            )
            moved = Hive::PatrolFix::Transition.new(task).apply_publication_block!(receipt)
            unless Hive::Lock.release_task_lock(
              moved.fetch(:task_folder), lock_id: lock.fetch("lock_id")
            )
              raise Hive::PatrolFix::Transition::InvalidTransition,
                    "publication rework task lock could not be released after the move"
            end
          end
        end
      end

      def dispatch_stage_action(verb, task, project_name, stage, guard)
        require "hive/commands/stage_action"
        Hive::Commands::StageAction.new(
          verb, task.folder, project: project_name, from: stage,
          quiet: true, observation_guard: guard
        ).call
      end

      def dispatch_outcome_evidence_rework(task, project_name, observed)
        require "hive/commands/evidence"
        attrs = observed.fetch("attrs")
        Hive::Commands::Evidence.new(
          "rework", task.folder, project: project_name,
          stage: observed.fetch("stage"), generation: attrs.fetch("generation"),
          recovery_digest: attrs.fetch("recovery_digest"),
          task_resolver: -> { task }, quiet: true
        ).call
      end

      def dispatch_run(task, project_name, stage, guard)
        require "hive/commands/run"
        Hive::Commands::Run.new(
          task.folder, project: project_name, stage: stage,
          quiet: true, observation_guard: guard
        ).call
      end

      def dispatch_approve(task, project_name, observed, guard)
        require "hive/commands/approve"
        Hive::Commands::Approve.new(
          task.folder, from: observed.fetch("stage"), project: project_name,
          force: observed.fetch("marker") == "none", quiet: true,
          observation_guard: guard
        ).call
      end

      def result_for(project_name, slug)
        task = resolve_task(slug, project_name)
        row = OperationalAction.observed_row(task, project: project_name)
        {
          "task_state" => row.fetch("action"),
          "stage" => row.fetch("stage"),
          "marker" => row.fetch("marker")
        }
      rescue Hive::StaleOperationalObservation
        { "task_state" => "archived", "stage" => nil, "marker" => nil }
      end

      def recovery_result(observed, receipt)
        {
          "task_state" => observed.fetch("action"),
          "stage" => observed.fetch("stage"),
          "marker" => observed.fetch("marker"),
          "recovery" => receipt.to_h
        }
      end
    end
  end
end
