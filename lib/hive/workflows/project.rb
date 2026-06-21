require "hive/workflows/loader"
require "hive/workflows/registry"

module Hive
  module Workflows
    module Project
      module_function

      # Per-root memoized: once a project_root's overlay is active we
      # early-return, so descriptors written AFTER the first load! of that root
      # are NOT picked up until `reset!` clears @active_root and the
      # loaded_workflows cache. A caller that scaffolds a new descriptor and
      # needs it visible in the SAME process (e.g. `hive workflow new`) must
      # call `reset!` afterwards — that coupling is why
      # Commands::Workflow#call! resets before re-resolving.
      def load!(project_root)
        project_root = File.expand_path(project_root)
        return if @active_root == project_root

        # Clear the prior project's overlay BEFORE loading, and drop
        # @active_root to nil first. @active_root is re-set to the new root only
        # after a clean load completes, so a failure partway through can't leave
        # @active_root pinned to a root whose overlay is now empty — which would
        # make the next same-root load! short-circuit and serve a stale/empty
        # registry for the rest of a long-lived TUI/daemon session.
        Hive::Workflows::Registry.reset_project_registrations!
        @active_root = nil

        workflow_dir = workflow_dir_for(project_root)
        workflows = loaded_workflows.fetch(project_root) do
          loaded_workflows[project_root] = Hive::Workflows::Loader.load_dir(workflow_dir)
        end
        workflows.each_value { |workflow| register_descriptor(workflow, workflow_dir) }
        # No trailing reset_union_cache! here: both register! and
        # reset_project_registrations! already invalidate the union cache, so an
        # explicit call would be dead in every path (and re-spell the
        # respond_to? guard the registry already encapsulates).
        @active_root = project_root
      end

      def register_descriptor(workflow, workflow_dir)
        Hive::Workflows::Registry.register!(
          workflow,
          project: true,
          source_path: File.join(workflow_dir, "#{workflow.id}.yml")
        )
      rescue Hive::ConfigError => e
        # A descriptor whose id collides with a built-in (or another already-
        # registered project workflow) must not brick the whole project: the
        # eager Project.load! in Task#initialize runs for EVERY task, including
        # built-in coding ones. Skip the colliding descriptor with a stderr
        # breadcrumb so the rest of the project still loads.
        warn "hive: skipping #{e.message}"
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
      rescue Hive::ConfigError, Psych::Exception, SystemCallError, IOError => e
        fallback = File.join(project_root, Hive::Config::DEFAULTS.fetch("hive_state_path"), "workflows")
        # Surface the fallback so a project with a CUSTOM hive_state_path whose
        # config.yml is unreadable doesn't silently load descriptors from the
        # wrong (default) directory — its workflows would otherwise go
        # unregistered and resurface later as a confusing "unknown workflow".
        warn "hive: workflow loader: could not read hive_state_path for #{project_root} " \
             "(#{e.class}: #{e.message}); falling back to #{fallback}"
        fallback
      end
    end
  end
end
