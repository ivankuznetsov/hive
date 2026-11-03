require "hive"
require "hive/commands/status"
require "hive/task_resolver"

module Hive
  module Web
    # Resolves one registered project/task without entering the fleet status
    # producer. A cached row is presentation data only: TaskResolver still
    # proves that the task currently exists in the selected project. Archive
    # mode disables retention only for that resolved project/stage.
    class TaskTargetResolver
      Result = Data.define(:native_task, :attributes, :source)

      def initialize(project:, slug:, cached_payload: nil, archive: false,
                     status_command: nil, task_resolver: nil)
        @project = project.to_h
        @slug = slug.to_s
        @cached_payload = cached_payload
        @status_command =
          status_command || Hive::Commands::Status.new(json: true, archive: archive)
        @task_resolver = task_resolver || lambda do
          Hive::TaskResolver.new(@slug, project_filter: @project.fetch("name")).resolve
        end
      end

      def call
        native_task = @task_resolver.call
        validate_native_identity!(native_task)
        # The exact status path owns durable failed-edit recovery too. Cached
        # failure/input bindings may have been superseded by edits or accepted
        # output. Legacy marker receipts retain their existing cache overlay.
        attributes = targeted_attributes(native_task)
        cached = cached_attributes(native_task)
        if attributes && attributes.dig("recovery", "variant") != "failed_edit" &&
           cached && cached["recovery"].is_a?(Hash) && cached.dig("recovery", "variant") != "failed_edit"
          attributes["recovery"] = cached["recovery"]
        end
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
        payload = @status_command.task_target_payload(
          @project,
          slug: native_task.slug,
          stage: stage
        )
        if payload["error"] == "project_load_failed"
          raise Hive::Error,
                "project #{@project.fetch('name')} status is unavailable — " \
                "repair its configuration or workflow, then reload"
        end
        if @status_command.respond_to?(:with_operational_recoveries)
          envelope = {
            "schema" => "hive-status", "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
            "ok" => true, "generated_at" => Time.now.utc.iso8601(6), "projects" => [ payload ]
          }
          payload = @status_command.with_operational_recoveries(envelope).fetch("projects").first
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
