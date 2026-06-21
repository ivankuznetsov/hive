require "hive/config"
require "hive/workflows/descriptor_parser"

module Hive
  module Workflows
    module Loader
      module_function

      def load(project_root)
        load_dir(workflow_dir(project_root))
      end

      # Canonical "<hive_state_path>/workflows" resolver. The single spelling of
      # this path — Hive::Workflows::Project#workflow_dir_for wraps it with a
      # config-error fallback, and Hive::Commands::Workflow#workflow_dir
      # delegates here for scaffolding. `expand_path(..., project_root)` resolves
      # a relative hive_state_path against the project and honors an absolute
      # one, where a bare File.join would mis-concatenate.
      def workflow_dir(project_root)
        project_root = File.expand_path(project_root)
        cfg = Hive::Config.load(project_root)
        File.join(File.expand_path(cfg.fetch("hive_state_path"), project_root), "workflows")
      end

      def load_dir(workflows_dir)
        return {} unless File.directory?(workflows_dir)

        Dir.glob(File.join(workflows_dir, "*.yml")).sort.each_with_object({}) do |path, workflows|
          # Per-file isolation (plan U9-2: "good one loads, broken one reported
          # with its path"). One malformed descriptor must NOT abort loading its
          # siblings — that would brick every task in the project, including
          # built-in coding tasks that never touch the new workflow. Report the
          # broken file with its path on stderr (the ConfigError message already
          # embeds the path) and skip it; the good descriptors still load.
          begin
            workflow = Hive::Workflows::DescriptorParser.parse_file(path)
            workflows[workflow.id] = workflow
          rescue Hive::ConfigError => e
            warn "hive: skipping #{e.message}"
          end
        end
      end
    end
  end
end
