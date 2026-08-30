require "json"
require "hive"
require "hive/config"
require "hive/lock"
require "hive/markers"
require "hive/task_projection/store"
require "hive/task_resolver"

module Hive
  module Commands
    # Rebuilds only one task's derived projection. This is deliberately a
    # direct operator verb, not a daemon recovery path or migration framework.
    class RepairProjection
      include Hive::Schemas::EnvelopeEmitter

      class RepairFailed < Hive::Error
        attr_reader :reason, :checkpoint_state, :terminal

        def initialize(message, reason:, checkpoint_state:, terminal:)
          super(message)
          @reason = reason.to_s
          @checkpoint_state = checkpoint_state.to_s
          @terminal = terminal == true
        end

        def exit_code
          terminal ? Hive::ExitCodes::SOFTWARE : Hive::ExitCodes::GENERIC
        end
      end

      def initialize(target, project: nil, stage: nil, json: false,
                     attempt_store: nil, resolver_factory: nil)
        @target = target
        @project_filter = project
        @stage_filter = stage
        @json = json
        @attempt_store = attempt_store
        @resolver_factory = resolver_factory || lambda do
          Hive::TaskResolver.new(
            @target, project_filter: @project_filter, stage_filter: @stage_filter
          )
        end
        @identity = nil
      end

      def call
        call_with_envelope { do_call }
      end

      def envelope_schema = "hive-repair-projection"

      def envelope_error_kind(error)
        case error
        when Hive::AmbiguousSlug then "ambiguous_slug"
        when Hive::InvalidTaskPath then "invalid_task_path"
        when Hive::ConcurrentRunError then "task_locked"
        when RepairFailed then "projection_repair_failed"
        when Hive::TaskProjection::InvalidJournal then "invalid_projection_authority"
        else "error"
        end
      end

      def envelope_extras_for(error)
        extras = { "outcome" => "failed" }
        extras.merge!(@identity) if @identity
        if error.is_a?(RepairFailed)
          extras.merge!(
            "checkpoint_state" => error.checkpoint_state,
            "reason" => error.reason,
            "terminal" => error.terminal,
            "next_action" => failure_next_action(error)
          )
        end
        extras
      end

      def envelope_serialization_failure_policy = :raise

      private

      def do_call
        raise Hive::UsageError, "hive repair-projection requires TARGET" if
          @target.to_s.strip.empty?

        task = resolve_task
        @identity = task_identity(task)
        payload = Hive::Lock.with_task_lock(
          task.folder,
          { "slug" => task.slug, "op" => "repair-projection" },
          create: false
        ) do
          locked_task = resolve_task
          locked_identity = task_identity(locked_task)
          unless locked_identity == @identity
            raise Hive::InvalidTaskPath,
                  "task identity changed before projection repair; resolve it again"
          end

          marker = Hive::Markers.current(locked_task.state_file)
          result = begin
            options = { task_folder: locked_task.folder }
            options[:attempt_store] = @attempt_store if @attempt_store
            Hive::TaskProjection::Store.new(**options).repair!(
              marker: marker,
              pristine: Hive::TaskProjection::Store.pristine_task?(
                locked_task, marker,
                held_task_lock: Hive::Lock.task_lock_held?(locked_task.folder)
              )
            )
          rescue Hive::TaskProjection::InvalidJournal => e
            raise Hive::TaskProjection::InvalidJournal,
                  "projection repair for #{identity_label} failed: #{e.message}"
          end
          bounded = result.bounded
          unless bounded.current?
            diagnostic = bounded.diagnostics.first || {}
            reason = diagnostic.fetch("reason", bounded.state).to_s
            terminal = Hive::TaskProjection.terminal_repair_reason?(reason)
            raise RepairFailed.new(
              failure_message(reason, bounded.state, terminal: terminal),
              reason: reason, checkpoint_state: bounded.state, terminal: terminal
            )
          end

          success_payload(bounded)
        end

        if @json
          puts JSON.generate(payload)
          @stdout_written = true
        else
          puts "Repaired projection for #{payload.fetch('project')}:#{payload.fetch('slug')} " \
               "(#{payload.fetch('stage')}); checkpoint is current at journal cursor " \
               "#{payload.fetch('journal_cursor')}."
          puts "Next: #{payload.dig('next_action', 'command')}"
        end
        payload
      end

      def resolve_task
        @resolver_factory.call.resolve
      end

      def task_identity(task)
        project = registered_project_for(task)
        {
          "project" => project.fetch("name").to_s,
          "slug" => task.slug.to_s,
          "task_id" => task.id&.to_s,
          "stage" => "#{task.stage_index}-#{task.stage_name}",
          "task_folder" => File.realpath(task.folder)
        }
      end

      def registered_project_for(task)
        root = File.realpath(task.project_root)
        project = Hive::Config.registered_projects.find do |entry|
          path = entry["path"].to_s
          !path.empty? && File.directory?(path) && File.realpath(path) == root
        rescue SystemCallError
          false
        end
        return project if project

        raise Hive::InvalidTaskPath,
              "projection repair requires a task in a registered project"
      end

      def success_payload(bounded)
        @identity.merge(
          "schema" => envelope_schema,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(envelope_schema),
          "ok" => true,
          "outcome" => "repaired",
          "checkpoint_state" => bounded.state,
          "journal_cursor" => bounded.journal_cursor,
          "terminal" => false,
          "next_action" => {
            "kind" => "refresh_status",
            "command" => "hive status --operational --json"
          }
        )
      end

      def failure_next_action(error)
        if error.terminal
          {
            "kind" => "compact_projection_history",
            "instructions" =>
              "compact this task's retained projection history before repairing again"
          }
        else
          {
            "kind" => "retry_exact_repair",
            "command" => exact_repair_command
          }
        end
      end

      def identity_label
        "#{@identity.fetch('project')}:#{@identity.fetch('slug')}"
      end

      def exact_repair_command
        Hive::TaskProjection.repair_command(
          project: @identity.fetch("project"), slug: @identity.fetch("slug"),
          stage: @identity.fetch("stage")
        )
      end

      def failure_message(reason, checkpoint_state, terminal:)
        message = "projection repair for #{identity_label} did not produce a current " \
                  "bounded checkpoint (#{checkpoint_state}: #{reason})"
        return "#{message}; compact this task's retained projection history" if terminal

        "#{message}; retry with #{exact_repair_command}"
      end
    end
  end
end
