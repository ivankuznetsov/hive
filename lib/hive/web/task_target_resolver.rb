require "hive"
require "hive/commands/status"
require "hive/task_resolver"

module Hive
  module Web
    # Resolves one registered project/task without entering the fleet status
    # producer. A cached row is presentation data only: TaskResolver still
    # proves that the task currently exists in the selected project.
    class TaskTargetResolver
      Result = Data.define(:native_task, :attributes, :source)

      def initialize(project:, slug:, cached_payload: nil,
                     status_command: Hive::Commands::Status.new(json: true),
                     task_resolver: nil)
        @project = project.to_h
        @slug = slug.to_s
        @cached_payload = cached_payload
        @status_command = status_command
        @task_resolver = task_resolver || lambda do
          Hive::TaskResolver.new(@slug, project_filter: @project.fetch("name")).resolve
        end
      end

      def call
        native_task = @task_resolver.call
        validate_native_identity!(native_task)
        # The cached fleet row can lag a task mutation by up to one poll
        # interval. Resolve the exact current row first, then overlay only the
        # daemon-owned recovery receipt that the targeted status path does not
        # derive. This keeps task controls current without a fleet scan.
        attributes = targeted_attributes(native_task)
        cached = cached_attributes(native_task)
        attributes["recovery"] = cached["recovery"] if
          attributes && cached && cached["recovery"].is_a?(Hash)
        raise Hive::InvalidTaskPath, "unknown task #{@slug}" unless attributes

        Result.new(native_task:, attributes:, source: "targeted")
      end

      private

      def cached_attributes(native_task)
        project = Array(@cached_payload && @cached_payload["projects"]).find do |candidate|
          candidate["name"].to_s == @project.fetch("name").to_s
        end
        return if project&.fetch("error", nil)

        row = Array(project && project["tasks"]).find { |candidate| candidate["slug"].to_s == @slug }
        return unless row
        return unless same_folder?(row["folder"], native_task.folder)

        row
      end

      def targeted_attributes(native_task)
        stage = "#{native_task.stage_index}-#{native_task.stage_name}"
        payload = @status_command.project_payload(
          @project,
          project_count: 1,
          stages: [ stage ]
        )
        if payload["error"] == "project_load_failed"
          raise Hive::Error,
                "project #{@project.fetch('name')} status is unavailable — " \
                "repair its configuration or workflow, then reload"
        end
        Array(payload["tasks"]).find do |candidate|
          candidate["slug"].to_s == @slug &&
            same_folder?(candidate["folder"], native_task.folder)
        end
      end

      def validate_native_identity!(task)
        unless task.slug.to_s == @slug &&
               same_folder?(task.project_root, @project.fetch("path"))
          raise Hive::InvalidTaskPath, "task #{@slug} does not belong to project #{@project.fetch('name')}"
        end
      end

      def same_folder?(left, right)
        return false if left.to_s.empty? || right.to_s.empty?

        File.realpath(left) == File.realpath(right)
      rescue SystemCallError
        File.expand_path(left.to_s) == File.expand_path(right.to_s)
      end
    end
  end
end
