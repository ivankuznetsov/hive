require "hive"
require "hive/commands/status"
require "hive/task_resolver"
require "hive/task_meta"

module Hive
  module Web
    # Resolves one registered project/task without entering the fleet status
    # producer. A cached row is presentation data only: TaskResolver still
    # proves that the task currently exists in the selected project. Archive
    # mode disables retention only for that resolved project/stage.
    class TaskTargetResolver
      Result = Data.define(:native_task, :attributes, :source)
      UnavailableTask = Data.define(
        :slug, :project_root, :folder, :stage_index, :stage_name, :id
      ) do
        def workflow = nil
        def workflow_unavailable? = true
      end

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
        native_task = resolve_native_task
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

        source = native_task.respond_to?(:workflow_unavailable?) &&
                 native_task.workflow_unavailable? ? "unavailable_workflow" : "targeted"
        Result.new(native_task:, attributes:, source: source)
      end

      private

      def resolve_native_task
        @task_resolver.call
      rescue Hive::InvalidTaskPath => original_error
        folder = unavailable_task_folder
        raise original_error unless folder

        stage = File.basename(File.dirname(folder))
        index, name = stage.split("-", 2)
        meta = Hive::TaskMeta.read(folder)
        UnavailableTask.new(
          slug: @slug, project_root: File.expand_path(@project.fetch("path")),
          folder: folder, stage_index: Integer(index, 10), stage_name: name,
          id: meta[:id]
        )
      end

      # Status deliberately preserves a synthetic row when workflow policy can
      # no longer be loaded. Resolve only that exact registered project's
      # existing folder so the browser can present the inert diagnosis; this
      # fallback never manufactures a runnable Hive::Task.
      def unavailable_task_folder
        return unless Hive::Stages.task_slug?(@slug)

        stages_root = File.join(@project.fetch("hive_state_path"), "stages")
        return unless File.directory?(stages_root)

        real_stages_root = File.realpath(stages_root)
        matches = Dir.children(stages_root).sort.filter_map do |stage|
          next unless Hive::Workflows.stage_dir?(stage)

          candidate = File.join(stages_root, stage, @slug)
          next unless File.directory?(candidate)

          real = File.realpath(candidate)
          next unless real.start_with?("#{real_stages_root}#{File::SEPARATOR}")

          real
        end
        if matches.size > 1
          raise Hive::InvalidTaskPath,
                "task #{@slug} exists in multiple stage folders for project #{@project.fetch('name')}"
        end
        matches.first
      rescue Errno::ENOENT, Errno::EACCES, IOError
        nil
      end

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
