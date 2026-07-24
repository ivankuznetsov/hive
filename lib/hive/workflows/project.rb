require "monitor"
require "set"
require "shellwords"
require "hive/workflows/descriptor_parser"
require "hive/workflows/loader"
require "hive/workflows/registry"

module Hive
  module Workflows
    module Project
      module_function

      # Serializes the per-project `load!` + downstream resolve so the
      # module-level overlay state (@active_root / @loaded_workflows and the
      # Registry's project_registrations + union caches) is never swapped out
      # from under a concurrent reader. The web tier's StatusFeed runs
      # `json_payload` (→ load! per project, then resolve each task's workflow)
      # on BOTH a background poller thread and per-request threads; without this
      # lock a `load!(B)` on one thread could clear project A's overlay while
      # another thread is mid-resolve of A, making A's custom-workflow rows
      # raise UnknownWorkflow and degrade the project. A Monitor (reentrant) so
      # the eager Task#initialize → load! and the status call's own
      # `synchronize { load!; resolve }` can re-enter without deadlocking.
      LOCK = Monitor.new

      # Run a block with the project overlay held stable. Callers that load a
      # project then resolve against its overlay (e.g. `hive status`'s
      # per-project payload) wrap BOTH steps in this so no other thread swaps
      # the active root between the load and the resolve.
      def synchronize(&block)
        LOCK.synchronize(&block)
      end

      # Per-root memoized: once a project_root's overlay is active we
      # early-return, so descriptors written AFTER the first load! of that root
      # are NOT picked up until `reset!` clears @active_root and the
      # loaded_workflows cache. A caller that scaffolds a new descriptor and
      # needs it visible in the SAME process (e.g. `hive workflow new`) must
      # call `reset!` afterwards — `reset!` is why Commands::Workflow#call!
      # clears the overlay so a LATER (separate) invocation discovers the new
      # descriptor; `call!` does not re-resolve in-process.
      def load!(project_root, config: nil, hive_state_path: nil)
        LOCK.synchronize do
          project_root = File.expand_path(project_root)
          if config || hive_state_path
            workflow_dir = workflow_dir_for(
              project_root, config: config, hive_state_path: hive_state_path
            )
            return load_overlay!(project_root, workflow_dir)
          end

          source_path, data = project_config_source(project_root)
          unless data
            return load_overlay!(project_root, fallback_workflow_dir(project_root))
          end
          data = Hive::Config.normalize_legacy_project_config(data, source_path)

          configured_path = data["hive_state_path"]
          configured_path = Hive::Config::DEFAULTS.fetch("hive_state_path") unless configured_path.is_a?(String)
          workflow_dir = begin
            workflow_dir_for(project_root, hive_state_path: configured_path)
          rescue ArgumentError
            Hive::Config.validate_project_top_level_keys!(
              data, source_path, project_root, stage_names: []
            )
            raise
          end
          load_overlay!(project_root, workflow_dir)

          begin
            Hive::Config.build_project_config(
              project_root, source_path, data, stage_names: registered_stage_names
            )
          rescue Hive::UnsupportedProjectConfigError
            raise
          rescue Hive::ConfigError, Psych::Exception, SystemCallError, IOError => e
            warn_config_fallback(project_root, e)
            load_overlay!(project_root, fallback_workflow_dir(project_root))
          end
        end
      end

      # Config.load calls this only when raw keys need a project-authored stage
      # vocabulary. Reuse the active overlay without another directory scan;
      # otherwise load from the already-parsed hive_state_path, which never
      # calls Config.load and therefore cannot complete a reverse load cycle.
      def stage_names_for_config(project_root, hive_state_path:)
        LOCK.synchronize do
          project_root = File.expand_path(project_root)
          workflow_dir = workflow_dir_for(project_root, hive_state_path: hive_state_path)
          load_overlay!(project_root, workflow_dir) unless active_overlay?(project_root, workflow_dir)
          registered_stage_names
        end
      end

      # This file is intentionally loadable without the aggregate
      # `hive/workflows` entrypoint (for example, `hive markers clear` reaches
      # it through Task). Read the registry directly so strict config
      # validation cannot depend on `Workflows.all_stage_names` having been
      # defined by a different command's require order.
      def registered_stage_names
        Hive::Workflows::Registry.all.flat_map(&:stage_names).uniq
      end
      private_class_method :registered_stage_names

      def load_overlay!(project_root, workflow_dir)
        # Include the resolved directory so changing hive_state_path cannot
        # reuse an overlay cached from a different, equally empty directory.
        fingerprint = [ workflow_dir, *Hive::Workflows::Loader.fingerprint(workflow_dir) ].freeze
        return if @active_root == project_root && @active_fingerprint == fingerprint

        # Clear the prior project's overlay BEFORE loading, and drop
        # @active_root to nil first. @active_root is re-set to the new root only
        # after a clean load completes, so a failure partway through can't leave
        # @active_root pinned to a root whose overlay is now empty — which would
        # make the next same-root load! short-circuit and serve a stale/empty
        # registry for the rest of a long-lived TUI/daemon session.
        Hive::Workflows::Registry.reset_project_registrations!
        @active_root = nil

        cached = loaded_workflows[project_root]
        workflows = if cached && cached.fetch(:fingerprint) == fingerprint
                      cached.fetch(:workflows)
        else
                      Hive::Workflows::Loader.load_dir(workflow_dir).tap do |loaded|
                        loaded_workflows[project_root] = { fingerprint: fingerprint, workflows: loaded }
                      end
        end
        workflows.each_value { |workflow| register_descriptor(workflow, workflow_dir, project_root) }
        # No trailing reset_union_cache! here: both register! and
        # reset_project_registrations! already invalidate the union cache, so an
        # explicit call would be dead in every path (and re-spell the
        # respond_to? guard the registry already encapsulates).
        @active_root = project_root
        @active_fingerprint = fingerprint
      end

      def active_overlay?(project_root, workflow_dir)
        @active_root == project_root && @active_fingerprint&.first == workflow_dir
      end

      def project_config_source(project_root)
        Hive::Config.read_project_config(project_root)
      rescue Hive::ConfigError, Psych::Exception, SystemCallError, IOError => e
        warn_config_fallback(project_root, e)
        [ nil, nil ]
      end

      def fallback_workflow_dir(project_root)
        File.join(project_root, Hive::Config::DEFAULTS.fetch("hive_state_path"), "workflows")
      end

      def warn_config_fallback(project_root, error)
        fallback = fallback_workflow_dir(project_root)
        warn "hive: workflow loader: could not read hive_state_path for #{project_root} " \
             "(#{error.class}: #{error.message}); falling back to #{fallback}"
      end

      def register_descriptor(workflow, workflow_dir, project_root)
        source_path = File.join(workflow_dir, "#{workflow.id}.yml")
        if Hive::Workflows::Bench.legacy_project_descriptor?(workflow, source_path: source_path) &&
           warned_skips.add?(source_path)
          warn "hive: legacy bench workflow at #{source_path} remains active; " \
               "run `hive init #{Shellwords.escape(project_root)} --workflow bench` to migrate to the built-in"
        end
        Hive::Workflows::Registry.register!(workflow, project: true, source_path: source_path)
      rescue Hive::ConfigError => e
        # A descriptor whose id collides with a built-in (or another already-
        # registered project workflow) must not brick the whole project: the
        # eager Project.load! in Task#initialize runs for EVERY task, including
        # built-in coding ones. Skip the colliding descriptor with a stderr
        # breadcrumb so the rest of the project still loads. Dedup the warn per
        # source_path: only the parse result is cached in loaded_workflows, so
        # register_descriptor re-runs on every load! that swaps @active_root —
        # a multi-project daemon alternating roots would otherwise re-emit this
        # line every status tick (unbounded log flood). The explicitly-requested
        # collision still surfaces loudly at the resolution boundary
        # (assert_descriptor_loadable!), so suppressing the repeat here loses no
        # signal.
        warn "hive: skipping #{e.message}" if warned_skips.add?(source_path)
      end

      # When a workflow id is named explicitly (`hive new --workflow <id>` /
      # `hive init`), a descriptor FILE for that id that was skipped at load
      # time must surface its REAL error at the resolution boundary instead of
      # resolving to a built-in (collision) or raising a misleading
      # UnknownWorkflow (parse error). U9-3: never silently shadow the coding
      # pipeline. Load-time sibling isolation is unchanged — this re-reads ONLY
      # the one explicitly-requested descriptor, and only when it didn't already
      # register cleanly.
      def assert_descriptor_loadable!(id, project_root:)
        return if id.nil?
        # Registered cleanly as a project overlay → nothing to surface.
        return if Hive::Workflows::Registry.project_registrations.key?(id.to_sym)

        path = File.join(workflow_dir_for(File.expand_path(project_root)), "#{id}.yml")
        return unless File.file?(path)

        # The file exists but is absent from the project overlay. Re-parse it:
        # a malformed descriptor re-raises its real ConfigError here; a clean
        # parse means register! refused it for colliding with an already-
        # registered (built-in or runtime) workflow — reproduce that error.
        Hive::Workflows::DescriptorParser.parse_file(path)
        raise Hive::ConfigError,
              "workflow descriptor #{path} collides with registered workflow #{id.to_sym.inspect}"
      end

      def reset!
        LOCK.synchronize do
          @active_root = nil
          @active_fingerprint = nil
          loaded_workflows.clear
          warned_skips.clear
          Hive::Workflows::Registry.reset_project_registrations!
        end
      end

      # Bounded-K assumption: one parsed-descriptor entry accumulates per
      # project-root for the daemon's whole lifetime, evicted only by the
      # all-or-nothing reset!. Harmless at today's handful of registered
      # projects, but a future live-reload / lazy-load author must keep the
      # @loaded_workflows ⇆ @active_root coupling in mind (the per-root memo is
      # only consistent with the single active overlay load! installs).
      def loaded_workflows
        @loaded_workflows ||= {}
      end

      # Source paths whose skip warning has already been emitted this process,
      # so the collision/parse-skip breadcrumb fires once per file rather than
      # on every overlay swap. Cleared by reset!.
      def warned_skips
        @warned_skips ||= Set.new
      end

      def workflow_dir_for(project_root, config: nil, hive_state_path: nil)
        return Hive::Workflows::Loader.workflow_dir(project_root, hive_state_path: hive_state_path) unless hive_state_path.nil?
        return Hive::Workflows::Loader.workflow_dir(project_root, config: config) if config

        Hive::Workflows::Loader.workflow_dir(project_root)
      rescue Hive::UnsupportedProjectConfigError
        raise
      rescue Hive::ConfigError, Psych::Exception, SystemCallError, IOError => e
        # Surface the fallback so a project with a CUSTOM hive_state_path whose
        # config.yml is unreadable doesn't silently load descriptors from the
        # wrong (default) directory — its workflows would otherwise go
        # unregistered and resurface later as a confusing "unknown workflow".
        warn_config_fallback(project_root, e)
        fallback_workflow_dir(project_root)
      end
    end
  end
end
