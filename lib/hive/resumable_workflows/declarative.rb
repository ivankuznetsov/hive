require "json"
require "shellwords"
require "hive/provider_routing/configuration"
require "hive/resumable_workflow"

module Hive
  module ResumableWorkflows
    class Declarative
      def initialize(workflow:, metadata:)
        @workflow = workflow
        @metadata = metadata
      end

      def snapshot(row:, project_root:, config:)
        _ = [ project_root, config ]
        path = File.expand_path(@metadata.fetch("snapshot"), row.folder)
        root = File.expand_path(row.folder)
        unless path.start_with?("#{root}#{File::SEPARATOR}")
          raise Hive::ResumableWorkflow::SnapshotError,
                "declared resumable snapshot escapes task folder: #{path}"
        end

        Hive::ResumableWorkflow::Snapshot.from_h(
          JSON.parse(File.read(path)),
          source: path
        )
      rescue JSON::ParserError => e
        raise Hive::ResumableWorkflow::SnapshotError,
              "declared resumable snapshot #{path} is invalid JSON: #{e.message}"
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Hive::ResumableWorkflow::SnapshotError,
              "declared resumable snapshot #{path} is unavailable: #{e.message}"
      end

      def configuration_for(child:, row:, config:)
        stage_name = row.stage.to_s.sub(/\A\d+-/, "")
        stage = @workflow.stage_for_dir(row.stage) || @workflow.stage_named(stage_name)
        Hive::ProviderRouting::Configuration.from(
          cfg: config,
          stage_name: stage_name,
          routing: child.routing || stage&.routing,
          agent: stage&.agent,
          model: stage&.model,
          effort: stage&.effort,
          source: "resumable workflow #{@workflow.id}.#{stage_name}"
        )
      end

      def resume_command(row:, snapshot:)
        _ = snapshot
        return row.suggested_command unless row.suggested_command.to_s.strip.empty?

        "hive run #{Shellwords.escape(row.slug.to_s)}"
      end
    end
  end
end
