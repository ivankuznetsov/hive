require "monitor"
require "set"
require "shellwords"
require "hive/workflows/descriptor_parser"
require "hive/workflows/loader"
require "hive/workflows/registry"
require "hive/warnings"

module Hive
  module Workflows
    module Project
      module_function

      class NestedProjectActivationError < Hive::Error
        attr_reader :active_root, :requested_root, :active_workflow_dir, :requested_workflow_dir

        def initialize(active_root, requested_root, active_workflow_dir: nil, requested_workflow_dir: nil)
          @active_root = active_root
          @requested_root = requested_root
          @active_workflow_dir = active_workflow_dir
          @requested_workflow_dir = requested_workflow_dir
          message = if active_workflow_dir && requested_workflow_dir
                      "cannot activate workflow directory #{requested_workflow_dir} while " \
                        "#{active_workflow_dir} is active on this thread"
          else
                      "cannot activate project #{requested_root} while project #{active_root} " \
                        "is active on this thread"
          end
          super(message)
        end
      end

      # Serializes each project operation so the module-level overlay state
      # (@active_root / @loaded_workflows and the Registry's project
      # registrations + union caches) is never swapped out from under a live
      # reader. The web tier's StatusFeed runs project operations on both a
      # background poller thread and per-request threads; without this lock an
      # operation for project B could clear project A's overlay while another
      # thread is resolving A. A Monitor keeps same-root configuration
      # validation reentrant without exposing caller-owned load choreography.
      LOCK = Monitor.new
      ACTIVE_OPERATION_KEY = :hive_workflows_project_active_operation
      ActivationBootstrap = Data.define(
        :source_path, :data, :workflow_dir, :validate_config, :fallback, :fallback_from
      )
      PreparedOverlay = Data.define(:workflow_dir, :fingerprint, :workflows)

      class FallbackActivation < StandardError
        attr_reader :workflow_dir, :fallback_from, :cause_error

        def initialize(workflow_dir, fallback_from, cause_error)
          @workflow_dir = workflow_dir
          @fallback_from = fallback_from
          @cause_error = cause_error
          super(cause_error.message)
        end
      end
      private_constant :ActivationBootstrap, :PreparedOverlay, :FallbackActivation

      # Run a block with the project overlay held stable. Callers that load a
      # project then resolve against its overlay (e.g. `hive status`'s
      # per-project payload) wrap BOTH steps in this so no other thread swaps
      # the active root between the load and the resolve.
      def synchronize(&block)
        LOCK.synchronize(&block)
      end

      # Establish one authoritative, block-scoped view of a project's accepted
      # workflows. The Monitor stays held through the caller block, so another
      # thread cannot replace the process-wide project overlay between a
      # descriptor read and its corresponding stage-vocabulary read.
      def with_active_workflows(project_root, config: nil, hive_state_path: nil, &block)
        project_root = normalize_project_root(project_root)
        raise LocalJumpError, "no block given (yield)" unless block

        with_prepared_activation(
          project_root, config: config, hive_state_path: hive_state_path
        ) do
          if block_accepts_stage_names?(block)
            block.call(Hive::Workflows::Registry, registered_stage_names)
          else
            block.call(Hive::Workflows::Registry)
          end
        end
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
        project_root = normalize_project_root(project_root)
        with_prepared_activation(
          project_root, config: config, hive_state_path: hive_state_path
        ) { nil }
      end

      # Config.load calls this only when raw keys need a project-authored stage
      # vocabulary. Reuse the active overlay without another directory scan;
      # otherwise load from the already-parsed hive_state_path, which never
      # calls Config.load and therefore cannot complete a reverse load cycle.
      def stage_names_for_config(project_root, hive_state_path:)
        project_root = normalize_project_root(project_root)
        with_prepared_activation(
          project_root, hive_state_path: hive_state_path, reuse_active: true
        ) do
          registered_stage_names
        end
      end

      def with_prepared_activation(project_root, config: nil, hive_state_path: nil,
                                   reuse_active: false)
        assert_nested_root!(project_root)
        bootstrap = activation_bootstrap(
          project_root, config: config, hive_state_path: hive_state_path
        )

        if current_project_operation
          return with_project_operation(project_root) do
            activate_with_cleanup!(
              project_root, bootstrap: bootstrap,
              reuse_active: reuse_active || nested_project_operation?
            )
            yield
          end
        end

        prepared = reusable_active_overlay(project_root, bootstrap.workflow_dir) if reuse_active
        prepared ||= prepare_overlay(project_root, bootstrap.workflow_dir)
        begin
          with_project_operation(project_root) do
            activate_with_cleanup!(
              project_root, bootstrap: bootstrap, prepared: prepared,
              reuse_active: reuse_active
            )
            yield
          end
        rescue FallbackActivation => fallback
          warn_config_fallback(project_root, fallback.cause_error)
          fallback_bootstrap = ActivationBootstrap.new(
            source_path: nil,
            data: nil,
            workflow_dir: fallback.workflow_dir,
            validate_config: false,
            fallback: true,
            fallback_from: fallback.fallback_from
          )
          fallback_prepared = prepare_overlay(project_root, fallback.workflow_dir)
          with_project_operation(project_root) do
            activate_with_cleanup!(
              project_root, bootstrap: fallback_bootstrap, prepared: fallback_prepared,
              reuse_active: reuse_active
            )
            yield
          end
        end
      end
      private_class_method :with_prepared_activation

      def activate_with_cleanup!(project_root, bootstrap:, prepared: nil, reuse_active: false)
        activation = { reused_active: false }
        activate_project!(
          project_root, bootstrap: bootstrap, prepared: prepared,
          reuse_active: reuse_active || nested_project_operation?,
          activation: activation
        )
      rescue StandardError
        # A same-root nested validation may reuse the already-complete outer
        # view without touching it. Preserve that view when validation raises;
        # every attempted activation is cleared so no foreign or partial
        # overlay survives the failed operation.
        clear_incomplete_activation! unless activation[:reused_active] && nested_project_operation?
        raise
      end
      private_class_method :activate_with_cleanup!

      def activate_project!(project_root, bootstrap:, prepared:, reuse_active:, activation:)
        activate_overlay!(
          project_root, bootstrap.workflow_dir,
          reuse_active: reuse_active,
          activation: activation,
          fallback: bootstrap.fallback,
          fallback_from: bootstrap.fallback_from,
          prepared: prepared
        )
        return if activation[:reused_active] && nested_project_operation?
        return unless bootstrap.validate_config

        begin
          Hive::Config.build_project_config(
            project_root, bootstrap.source_path, bootstrap.data,
            stage_names: registered_stage_names
          )
        rescue Hive::UnsupportedProjectConfigError
          raise
        rescue Hive::ConfigError, Psych::Exception, SystemCallError, IOError => e
          raise FallbackActivation.new(
            fallback_workflow_dir(project_root), bootstrap.workflow_dir, e
          )
        end
      end
      private_class_method :activate_project!

      def activate_overlay!(project_root, workflow_dir, reuse_active:, activation:, fallback: false,
                            fallback_from: nil, prepared: nil)
        if reuse_active && active_overlay?(project_root, workflow_dir)
          activation[:reused_active] = true
          return
        end

        if reuse_active && nested_project_operation? && @active_root == project_root && @active_fingerprint
          activation[:reused_active] = true
          return if @active_fallback && @active_fallback_from == workflow_dir

          raise NestedProjectActivationError.new(
            project_root,
            project_root,
            active_workflow_dir: @active_fingerprint.first,
            requested_workflow_dir: workflow_dir
          )
        end

        activation[:reused_active] = false
        load_overlay!(
          project_root, workflow_dir, fallback: fallback, fallback_from: fallback_from,
          prepared: prepared
        )
      end
      private_class_method :activate_overlay!

      def activation_bootstrap(project_root, config:, hive_state_path:)
        if config || hive_state_path
          resolution = { fallback: false }
          workflow_dir = workflow_dir_for(
            project_root, config: config, hive_state_path: hive_state_path,
            resolution: resolution
          )
          return ActivationBootstrap.new(
            source_path: nil, data: nil, workflow_dir: workflow_dir,
            validate_config: false, fallback: resolution[:fallback], fallback_from: nil
          )
        end

        source_path, data = project_config_source(project_root)
        unless data
          return ActivationBootstrap.new(
            source_path: nil, data: nil,
            workflow_dir: fallback_workflow_dir(project_root),
            validate_config: false, fallback: false, fallback_from: nil
          )
        end

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
        ActivationBootstrap.new(
          source_path: source_path, data: data, workflow_dir: workflow_dir,
          validate_config: true, fallback: false, fallback_from: nil
        )
      end
      private_class_method :activation_bootstrap

      # Fingerprinting and descriptor/package I/O happen before entering the
      # process-wide Project Monitor. In particular, ManagedStore#selections
      # may wait on the cross-process package mutation flock; that wait must not
      # stop an unrelated project from using its already independent overlay.
      def prepare_overlay(project_root, workflow_dir)
        fingerprint = [ workflow_dir, *Hive::Workflows::Loader.fingerprint(workflow_dir) ].freeze
        cached = LOCK.synchronize do
          entry = loaded_workflows[project_root]
          entry if entry && entry.fetch(:fingerprint) == fingerprint
        end
        workflows = cached ? cached.fetch(:workflows) : Hive::Workflows::Loader.load_dir(workflow_dir)
        PreparedOverlay.new(
          workflow_dir: workflow_dir, fingerprint: fingerprint, workflows: workflows
        )
      rescue StandardError
        LOCK.synchronize { clear_incomplete_activation! }
        raise
      end
      private_class_method :prepare_overlay

      def reusable_active_overlay(project_root, workflow_dir)
        LOCK.synchronize do
          return unless active_overlay?(project_root, workflow_dir)

          cached = loaded_workflows[project_root]
          return unless cached && cached.fetch(:fingerprint) == @active_fingerprint

          PreparedOverlay.new(
            workflow_dir: workflow_dir,
            fingerprint: cached.fetch(:fingerprint),
            workflows: cached.fetch(:workflows)
          )
        end
      end
      private_class_method :reusable_active_overlay

      def block_accepts_stage_names?(block)
        positional = block.parameters.select { |kind, _name| [ :req, :opt, :rest ].include?(kind) }
        positional.any? { |kind, _name| kind == :rest } || positional.length >= 2
      end
      private_class_method :block_accepts_stage_names?

      # This file is intentionally loadable without the aggregate
      # `hive/workflows` entrypoint (for example, `hive markers clear` reaches
      # it through Task). Read the registry directly so strict config
      # validation cannot depend on `Workflows.all_stage_names` having been
      # defined by a different command's require order.
      def registered_stage_names
        Hive::Workflows::Registry.all.flat_map(&:stage_names).uniq
      end
      private_class_method :registered_stage_names

      def normalize_project_root(project_root)
        if project_root.nil? || project_root.to_s.strip.empty?
          raise ArgumentError, "project_root must not be nil or blank"
        end

        File.expand_path(project_root)
      end
      private_class_method :normalize_project_root

      def with_project_operation(project_root)
        LOCK.synchronize do
          thread = Thread.current
          operation = thread.thread_variable_get(ACTIVE_OPERATION_KEY)
          if operation && operation.fetch(:root) != project_root
            raise NestedProjectActivationError.new(operation.fetch(:root), project_root)
          end

          if operation
            operation[:depth] += 1
          else
            operation = { root: project_root, depth: 1 }
            thread.thread_variable_set(ACTIVE_OPERATION_KEY, operation)
          end

          begin
            yield
          ensure
            operation[:depth] -= 1
            thread.thread_variable_set(ACTIVE_OPERATION_KEY, nil) if operation[:depth].zero?
          end
        end
      end
      private_class_method :with_project_operation

      def current_project_operation
        Thread.current.thread_variable_get(ACTIVE_OPERATION_KEY)
      end
      private_class_method :current_project_operation

      def assert_nested_root!(project_root)
        operation = current_project_operation
        return unless operation && operation.fetch(:root) != project_root

        raise NestedProjectActivationError.new(operation.fetch(:root), project_root)
      end
      private_class_method :assert_nested_root!

      def nested_project_operation?
        operation = Thread.current.thread_variable_get(ACTIVE_OPERATION_KEY)
        operation && operation.fetch(:depth) > 1
      end
      private_class_method :nested_project_operation?

      def clear_incomplete_activation!
        Hive::Workflows::Registry.reset_project_registrations!
        @active_root = nil
        @active_fingerprint = nil
        @active_fallback = false
        @active_fallback_from = nil
      end
      private_class_method :clear_incomplete_activation!

      def load_overlay!(project_root, workflow_dir, fallback: false, fallback_from: nil,
                        prepared: nil)
        unless prepared&.workflow_dir == workflow_dir
          raise Hive::Error, "project workflow activation was not prepared"
        end
        fingerprint = prepared.fingerprint
        if @active_root == project_root && @active_fingerprint == fingerprint
          @active_fallback = fallback
          @active_fallback_from = fallback_from
          return
        end

        # Clear the prior project's overlay BEFORE loading, and drop
        # @active_root to nil first. @active_root is re-set to the new root only
        # after a clean load completes, so a failure partway through can't leave
        # @active_root pinned to a root whose overlay is now empty — which would
        # make the next same-root load! short-circuit and serve a stale/empty
        # registry for the rest of a long-lived TUI/daemon session.
        Hive::Workflows::Registry.reset_project_registrations!
        @active_root = nil
        @active_fingerprint = nil
        @active_fallback = false
        @active_fallback_from = nil

        cached = loaded_workflows[project_root]
        workflows = if cached && cached.fetch(:fingerprint) == fingerprint
                      cached.fetch(:workflows)
                    else
                      prepared.workflows.tap do |loaded|
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
        @active_fallback = fallback || !fallback_from.nil?
        @active_fallback_from = fallback_from
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
        Hive::Warnings.emit(
          "hive: workflow loader: could not read hive_state_path for #{project_root} " \
          "(#{error.class}: #{error.message}); falling back to #{fallback}"
        )
      end

      def register_descriptor(workflow, workflow_dir, project_root)
        source_path = File.join(workflow_dir, "#{workflow.id}.yml")
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
        if warned_skips.add?(source_path)
          Hive::Warnings.emit("hive: skipping #{e.message}")
        end
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
          @active_fallback = false
          @active_fallback_from = nil
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

      def workflow_dir_for(project_root, config: nil, hive_state_path: nil, resolution: nil)
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
        resolution[:fallback] = true if resolution
        fallback_workflow_dir(project_root)
      end
    end
  end
end
