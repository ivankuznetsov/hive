require "hive/workflows/loader"
require "hive/workflows/registry"

module Hive
  module Workflows
    module Project
      module_function

      def load!(project_root)
        project_root = File.expand_path(project_root)
        return if @active_root == project_root

        Hive::Workflows::Registry.reset_project_registrations!
        workflow_dir = workflow_dir_for(project_root)
        workflows = loaded_workflows.fetch(project_root) do
          loaded_workflows[project_root] = Hive::Workflows::Loader.load_dir(workflow_dir)
        end
        workflows.each_value do |workflow|
          Hive::Workflows::Registry.register!(
            workflow,
            project: true,
            source_path: File.join(workflow_dir, "#{workflow.id}.yml")
          )
        end
        Hive::Workflows.reset_union_cache! if Hive::Workflows.respond_to?(:reset_union_cache!)
        @active_root = project_root
      end

      def reset!
        @active_root = nil
        loaded_workflows.clear
        Hive::Workflows::Registry.reset_project_registrations!
      end

      def loaded_workflows
        @loaded_workflows ||= {}
      end

      def workflow_dir_for(project_root)
        Hive::Workflows::Loader.workflow_dir(project_root)
      rescue Hive::ConfigError, Psych::Exception, SystemCallError, IOError
        File.join(project_root, Hive::Config::DEFAULTS.fetch("hive_state_path"), "workflows")
      end
    end
  end
end
