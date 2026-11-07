require "hive/commands/status"
require "hive/commands/task"
require "hive/commands/answer"
require "hive/operational_action"
require "hive/web/task_diff"
require "hive/task_workspace/bounded_reader"
require "hive/secret_patterns"

module Hive
  module Remote
    # Semantic readers shared with the native CLI and browser. The API owns
    # project authorization and the public DTOs; no reader selects a client
    # checkout or interprets a caller-supplied filesystem path.
    class ReadService
      def status(projects:)
        Hive::Commands::Status.new.active_payload(projects)
      end

      def task(project:, task:)
        verify_target!(project, task)
        Hive::Commands::Task.new(task.slug, project: project.fetch("name")).payload_for(project: project, task: task)
      end

      def action(project:, task:)
        verify_target!(project, task)
        Hive::OperationalAction.descriptor_for_task(task, project: project.fetch("name"))
      end

      def questions(project:, task:)
        verify_target!(project, task)
        Hive::Commands::Answer.inventory(task.slug, project: project.fetch("name"))
      end

      def logs(project:, task:, max_bytes: 256 * 1024)
        document = self.task(project: project, task: task)
        reference = document.dig("diagnostic", "log", "reference")
        return unavailable_log unless reference.is_a?(Hash)
        log = Hive::Attempts::API.new.correlated_log_reader.read(reference)
        return unavailable_log unless log
        limit = bounded_limit(max_bytes, 256 * 1024)
        text = Hive::SecretPatterns.redact(log.fetch("tail").to_s)
        content = text.byteslice(0, limit).to_s.force_encoding(Encoding::UTF_8).scrub("")
        { "state" => "available", "content" => content,
          "truncated" => content.bytesize < text.bytesize || reference.fetch("size", 0) > content.bytesize,
          "continuation" => nil }
      end

      def diff(project:, task:, max_bytes: 512 * 1024)
        verify_target!(project, task)
        Hive::Web::TaskDiff.new(task: task, expected_root: project.fetch("path"),
          max_bytes: bounded_limit(max_bytes, 512 * 1024)).call
      end

      def artifacts(project:, task:)
        verify_target!(project, task)
        attributes = { "stage" => "#{task.stage_index}-#{task.stage_name}" }
        Hive::Commands::Task::ProjectionTask.new(native_task: task, attributes: attributes).artifact_panel
      end

      def artifact(project:, task:, reference:, max_bytes: 512 * 1024)
        verify_target!(project, task)
        declared = [ task.workflow.result.primary_artifact, *task.workflow.stages.map(&:state_file) ].compact.uniq
        raise Hive::InvalidTaskPath, "unknown artifact" unless declared.include?(reference)
        Hive::TaskWorkspace::BoundedReader.new(root: task.folder).read(reference,
          max_bytes: bounded_limit(max_bytes, 512 * 1024))
      end

      private

      def verify_target!(project, task)
        unless task.is_a?(Hive::Task) && File.realpath(task.project_root) == File.realpath(project.fetch("path"))
          raise Hive::InvalidTaskPath, "task does not belong to the selected project"
        end
      end

      def bounded_limit(value, maximum)
        limit = Integer(value)
        raise Hive::UsageError, "read limit must be positive" unless limit.positive?
        [ limit, maximum ].min
      rescue ArgumentError, TypeError
        raise Hive::UsageError, "read limit must be a positive integer"
      end

      def unavailable_log
        { "state" => "unavailable", "content" => nil, "truncated" => false, "continuation" => nil }
      end
    end
  end
end
