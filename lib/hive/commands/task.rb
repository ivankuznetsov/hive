require "json"
require "hive/config"
require "hive/commands/status"
require "hive/task_resolver"
require "hive/task_workspace/artifacts"
require "hive/task_workspace/builder"

module Hive
  module Commands
    # Read-only semantic inspection of one exact registered task. This command
    # intentionally reuses TaskWorkspace::Builder#semantic rather than growing
    # the fleet-wide hive-status contract or maintaining a CLI-only projector.
    class Task
      class ProjectionTask
        def initialize(native_task:, attributes:)
          @native_task = native_task
          @attributes = attributes
        end

        def [](key) = @attributes[key.to_s]

        def artifact_panel
          Hive::TaskWorkspace::Artifacts.new(
            task_root: @native_task.folder,
            references: artifact_references
          ).call
        end

        private

        def artifact_references
          workflow = @native_task.workflow
          current = workflow.stage_for_dir(self["stage"].to_s)&.state_file
          [
            workflow.result.primary_artifact,
            current,
            *workflow.stages.map(&:state_file)
          ].compact.uniq
        end
      end

      def initialize(target, project: nil, json: false, clock: -> { Time.now.utc })
        @target = target
        @project_filter = project
        @json = json == true
        @clock = clock
      end

      def call
        native_task = Hive::TaskResolver.new(
          @target, project_filter: @project_filter
        ).resolve
        project = registered_project!(native_task)
        attributes, archived, observed_at = status_attributes(project, native_task)
        task = ProjectionTask.new(native_task: native_task, attributes: attributes)
        document = Hive::TaskWorkspace::Builder.new(
          task: task,
          native_task: native_task,
          project: project.fetch("name"),
          status_availability: "fresh",
          status_last_success_at: observed_at,
          cursor_codec: nil,
          archive: archived,
          clock: @clock
        ).semantic

        @json ? puts(JSON.generate(document)) : render(document)
        document
      end

      private

      def registered_project!(task)
        project = Hive::Config.registered_projects.find do |entry|
          File.expand_path(entry.fetch("path")) == File.expand_path(task.project_root)
        end
        raise Hive::Error, "task project is not registered" unless project

        project
      end

      def status_attributes(project, task)
        now = @clock.call.utc
        stage = "#{task.stage_index}-#{task.stage_name}"
        ordinary = status_project(project, archive: false, stage: stage)
        row = Array(ordinary["tasks"]).find { |item| item["slug"] == task.slug }
        return [ row, row["action"] == "archived", now.iso8601(6) ] if row

        archived = status_project(project, archive: true, stage: stage)
        row = Array(archived["tasks"]).find { |item| item["slug"] == task.slug }
        unless row
          raise Hive::InvalidTaskPath,
                "task #{task.slug.inspect} is unavailable in canonical status"
        end

        [ row, true, now.iso8601(6) ]
      end

      def status_project(project, archive:, stage:)
        Hive::Commands::Status.new(archive: archive).project_payload(
          project, project_count: 1, stages: [ stage ]
        )
      end

      def render(document)
        puts document.dig("headline", "label")
        puts "Action: #{document.dig('action', 'label') || 'None'}"
        primary = document.dig("result", "primary", "reference")
        puts "Primary result: #{primary || 'Not available'}"
        puts "Usage: #{document.dig('usage', 'coverage')}"
      end
    end
  end
end
