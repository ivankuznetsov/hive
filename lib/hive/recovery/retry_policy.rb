require "hive/config"
require "hive/recovery"
require "hive/workflows"
require "hive/workflows/project"

module Hive
  module Recovery
    # Neutral retry eligibility shared by the coordinator and user-facing
    # adapters. It identifies the ordinary workflow verb that owns a stage;
    # marker mutation, admission, pacing, and dispatch remain coordinator-only.
    module RetryPolicy
      module_function

      def verb_for(stage, workflow: nil, project: nil)
        stage = stage.to_s
        if Hive::Workflows.coding_id?(workflow)
          return nil if stage == "9-done" # coding-scoped: archived coding tasks have no retry verb

          return Hive::Workflows.verb_arriving_at(stage)
        end

        descriptor = resolve_descriptor(workflow, project: project)
        return "run" unless descriptor

        resolved_stage = descriptor.stage_for_dir(stage)
        return nil unless resolved_stage
        return nil unless %i[agent council].include?(resolved_stage.kind)

        "run"
      end

      def resolve_descriptor(workflow, project: nil)
        Hive::Workflows::Project.synchronize do
          load_project_overlay(project)
          Hive::Workflows::Registry.fetch(workflow.to_s.to_sym)
        end
      rescue Hive::Workflows::UnknownWorkflow
        nil
      end
      private_class_method :resolve_descriptor

      def load_project_overlay(project_name)
        return if project_name.nil? || project_name.to_s.empty?

        match = Hive::Config.registered_projects.find do |project|
          project["name"] == project_name.to_s
        end
        Hive::Workflows::Project.load!(match["path"]) if match
      end
      private_class_method :load_project_overlay
    end
  end
end
