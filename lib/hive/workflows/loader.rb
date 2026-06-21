require "hive/config"
require "hive/workflows/descriptor_parser"

module Hive
  module Workflows
    module Loader
      module_function

      def load(project_root)
        project_root = File.expand_path(project_root)
        cfg = Hive::Config.load(project_root)
        load_dir(File.join(project_root, cfg.fetch("hive_state_path"), "workflows"))
      end

      def load_dir(workflows_dir)
        return {} unless File.directory?(workflows_dir)

        Dir.glob(File.join(workflows_dir, "*.yml")).sort.each_with_object({}) do |path, workflows|
          workflow = Hive::Workflows::DescriptorParser.parse_file(path)
          workflows[workflow.id] = workflow
        end
      end
    end
  end
end
