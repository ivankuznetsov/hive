require "hive/config"
require "hive/workflows/descriptor_parser"
require "hive/workflow_package/managed_store"

module Hive
  module Workflows
    module Loader
      module_function

      # Canonical "<hive_state_path>/workflows" resolver. The single spelling of
      # this path — Hive::Workflows::Project#workflow_dir_for wraps it with a
      # config-error fallback, and Hive::Commands::Workflow#workflow_dir
      # delegates here for scaffolding. `expand_path(..., project_root)` resolves
      # a relative hive_state_path against the project and honors an absolute
      # one, where a bare File.join would mis-concatenate.
      def workflow_dir(project_root, config: nil)
        project_root = File.expand_path(project_root)
        cfg = config || Hive::Config.load(project_root)
        File.join(File.expand_path(cfg.fetch("hive_state_path"), project_root), "workflows")
      end

      def load_dir(workflows_dir)
        return {} unless File.directory?(workflows_dir)

        workflows = Dir.glob(File.join(workflows_dir, "*.yml")).sort.each_with_object({}) do |path, loaded|
          # Per-file isolation (plan U9-2: "good one loads, broken one reported
          # with its path"). One malformed descriptor must NOT abort loading its
          # siblings — that would brick every task in the project, including
          # built-in coding tasks that never touch the new workflow. Report the
          # broken file with its path on stderr (the ConfigError message already
          # embeds the path) and skip it; the good descriptors still load.
          begin
            workflow = Hive::Workflows::DescriptorParser.parse_file(path)
            loaded[workflow.id] = workflow
          rescue Hive::ConfigError => e
            warn "hive: skipping #{e.message}"
          end
        end
        load_managed(workflows_dir).each do |id, workflow|
          if workflows.key?(id)
            warn "hive: skipping managed workflow #{id.inspect}: owner-authored descriptor has priority"
          else
            workflows[id] = workflow
          end
        end
        workflows
      end

      def load_managed(workflows_dir)
        hive_state = File.dirname(workflows_dir)
        store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
        store.selections.each_with_object({}) do |lock, workflows|
          name = lock.fetch("name")
          workflow = store.workflow(
            name, lock.fetch("source_commit"), lock.fetch("manifest_digest"),
            configuration_digest: lock.fetch("configuration_digest"), verify_profiles: false
          )
          workflows[workflow.id] = workflow
        rescue Hive::ConfigError => e
          warn "hive: skipping managed workflow #{name.inspect}: #{e.message}"
        end
      end

      def fingerprint(workflows_dir)
        return [] unless File.directory?(workflows_dir)

        paths = Dir.glob(File.join(workflows_dir, "*.yml")) +
                Dir.glob(File.join(workflows_dir, "*", Hive::WorkflowPackage::ManagedStore::LOCK_FILE))
        paths.sort.map do |path|
          stat = File.stat(path)
          [ path, stat.mtime.to_f, stat.size ]
        rescue SystemCallError
          [ path, nil, nil ]
        end
      end
    end
  end
end
