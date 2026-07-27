require "yaml"
require "digest"
require "hive/config"
require "hive/stages"
require "hive/task_meta"
require "hive/workflows/project"
require "hive/workflows/registry"
require "hive/worktree"
require "hive/workflow_package/managed_store"

module Hive
  class Task
    WorkflowGeneration = Data.define(
      :config, :default_workflow, :workflows, :admission_config, :admission_config_error
    ) do
      def fetch(id)
        workflows.fetch(id.to_sym) do
          known = workflows.keys.map(&:inspect).join(", ")
          raise Hive::Workflows::UnknownWorkflow.new(
            "unknown workflow #{id.to_sym.inspect}; known workflows: #{known}",
            value: id.to_sym, valid: workflows.keys.map(&:to_s)
          )
        end
      end

      def stage_dirs = workflows.values.flat_map(&:stage_dirs).uniq.freeze
      def active_stage_dirs
        workflows.values.flat_map { |workflow| workflow.stages[0...-1].map(&:dir) }.uniq.freeze
      end
      def terminal_stage_dirs = workflows.values.map { |workflow| workflow.stages.last.dir }.uniq.freeze
    end

    # Coding-default only: pinned to Registry.default. Prefer the
    # descriptor-driven Task#stage_names instance accessor for workflow-aware
    # callers — these constants diverge for non-coding workflows (full consumer
    # migration is U6).
    STAGE_NAMES = Hive::Workflows::Registry.default.stages.map(&:name).freeze
    STATE_FILES = Hive::Workflows::Registry.default.stages.to_h { |stage| [ stage.name, stage.state_file ] }.freeze
    PATH_RE = %r{\A(?<root>.+)/(?<state_dir>\.hive-state)/stages/(?<stage_dir>(?<stage_idx>\d+)-(?<stage_name>[a-z][a-z0-9-]*))/(?<slug>[a-z][a-z0-9-]{0,62}[a-z0-9])/?\z}

    # Per-process cache of each project's resolved `default_workflow`, keyed by
    # the project's `.hive-state/config.yml` path and invalidated by its
    # (mtime, size) stamp. Without it `Task.new` re-ran a full `Hive::Config.load`
    # (file read + YAML parse + validate!) for every field-less task on every
    # `hive status` / daemon tick — a real per-tick regression, since
    # `resolve_workflow` only consults the project default when the task meta
    # carries no selector. Keying on (mtime, size) — not mtime alone — closes the
    # coarse-mtime window (FAT, some NFS) where a same-second rewrite that changes
    # the default would otherwise serve a long-lived reader (TUI / daemon) the
    # stale value until restart; negligible cost on ns-mtime ext4/xfs.
    @project_default_workflow_cache = {}

    class << self
      attr_reader :project_default_workflow_cache

      def capture_workflow_generation(
        project_root, config: Hive::Config.load(project_root),
        admission_config: config, admission_config_error: nil
      )
        config ||= Hive::Config::DEFAULTS
        configured = config["default_workflow"].to_s.strip
        configured = Hive::Config::DEFAULTS["default_workflow"] if configured.empty?
        WorkflowGeneration.new(
          config: config,
          default_workflow: configured,
          workflows: Hive::Workflows::Registry.workflows.dup.freeze,
          admission_config: admission_config,
          admission_config_error: admission_config_error
        )
      end
    end

    attr_reader :folder, :project_root, :hive_state_path, :stage_index,
                :stage_name, :slug, :state_dir_basename, :workflow, :action_workflow,
                :workflow_generation

    def workflow_commit = meta[:workflow_commit]
    def workflow_manifest_digest = meta[:workflow_manifest_digest]
    def workflow_configuration_digest = meta[:workflow_configuration_digest]
    def completed_at = meta[:completed_at]
    def managed_workflow? = !workflow_commit.nil? && !workflow_manifest_digest.nil?

    def managed_runtime_context(slot_id)
      return nil unless managed_workflow?

      store = Hive::WorkflowPackage::ManagedStore.new(@hive_state_path)
      root = store.generation_path(workflow.id.to_s, workflow_commit)
      manifest = store.manifest(workflow.id.to_s, workflow_commit, workflow_manifest_digest)
      metadata = manifest.data.fetch("x-hive", {})
      configuration = workflow_configuration_digest &&
                      store.configuration(workflow.id.to_s, workflow_configuration_digest)
      tools = Array(metadata["tools"]).map { |entry| File.join(root, entry.fetch("path")) }
      prompt_assets = Array(metadata["prompt_assets"]).map { |entry| File.join(root, entry.fetch("path")) }
      environment = configuration ? configuration.input_environment_for(slot_id, runtime_metadata: metadata) : {}
      statuses = configuration ? configuration.input_status_for(slot_id, runtime_metadata: metadata) : []
      {
        package_root: root,
        tools: tools,
        prompt_assets: prompt_assets,
        environment: environment,
        input_statuses: statuses
      }
    end

    def managed_prompt_preamble(slot_id, context = managed_runtime_context(slot_id))
      return nil unless context

      lines = [
        "Honeycomb package root (immutable, read-only): #{context.fetch(:package_root)}",
        "Executable slot: #{slot_id}"
      ]
      tools = context.fetch(:tools)
      lines << "Declared package tools: #{tools.join(', ')}" unless tools.empty?
      prompt_assets = context.fetch(:prompt_assets)
      lines << "Declared package prompt assets: #{prompt_assets.join(', ')}" unless prompt_assets.empty?
      statuses = context.fetch(:input_statuses)
      unless statuses.empty?
        summary = statuses.map do |entry|
          "#{entry.fetch('name')}=#{entry.fetch('available') ? 'available' : 'unavailable'}"
        end
        lines << "Optional inputs (values are never included in prompts): #{summary.join(', ')}"
      end
      lines.join("\n")
    end

    def managed_prompt(slot_id, body, context = managed_runtime_context(slot_id))
      preamble = managed_prompt_preamble(slot_id, context)
      preamble ? "#{preamble}\n\n#{body}" : body
    end

    def initialize(folder, workflow_generation: nil)
      folder = File.expand_path(folder)
      m = PATH_RE.match(folder)
      raise InvalidTaskPath, "task path must match <project>/.hive-state/stages/<N>-<name>/<slug>/: #{folder}" unless m

      @folder = folder.sub(%r{/\z}, "")
      @project_root = m[:root]
      @state_dir_basename = m[:state_dir]
      @hive_state_path = File.join(@project_root, m[:state_dir])
      @stage_index = m[:stage_idx].to_i
      @stage_name = m[:stage_name]
      @slug = m[:slug]
      @workflow_generation = workflow_generation
      @workflow = resolve_workflow
      @action_workflow = validate_workflow_stage!(m[:stage_dir], @workflow)
    end

    def project_name
      File.basename(@project_root)
    end

    def state_file
      File.join(@folder, action_workflow.state_file_for(@stage_name))
    end

    def stage_names
      workflow.stage_names
    end

    def reviews_dir
      File.join(@folder, "reviews")
    end

    def worktree_yml_path
      File.join(@folder, "worktree.yml")
    end

    def meta_yml_path
      Hive::TaskMeta.path(@folder)
    end

    def id
      meta[:id]
    end

    def display_name
      meta[:display_name]
    end

    def depends_on
      meta[:depends_on]
    end

    def base_branch
      meta[:base_branch]
    end

    def display_label
      display_name || slug
    end

    def worktree_path
      # An explicit pointer is authoritative for every workflow. Generic
      # managed workflows may create a worktree before coding's 4-execute
      # stage, while legacy coding tasks still derive a path only from stage 4.
      if File.exist?(worktree_yml_path)
        data = YAML.safe_load(File.read(worktree_yml_path)) || {}
        return data["path"] if data.is_a?(Hash) && data["path"]
      end
      return nil if @stage_index < 4

      derive_worktree_path
    end

    def derive_worktree_path
      cfg = Hive::Config.load(@project_root)
      template = cfg["worktree_root"] || Hive::Worktree.default_worktree_root(project_name)
      File.join(File.expand_path(template), @slug)
    end

    def lock_file
      File.join(@folder, ".lock")
    end

    def log_dir
      File.join(@hive_state_path, "logs", @slug)
    end

    def commit_lock_file
      File.join(@hive_state_path, ".commit-lock")
    end

    private

    def meta
      @meta ||= Hive::TaskMeta.read(@folder)
    end

    # Self-locking: the per-project overlay load and the subsequent registry
    # fetch are held together under Project::LOCK (a reentrant Monitor), so a
    # concurrent `load!(otherProject)` on another thread — the web tier runs
    # this on both a StatusFeed poller and per-request Puma threads — can't
    # swap the overlay between the load and the fetch and make a custom-workflow
    # task resolve as UnknownWorkflow / against the wrong descriptor. The lock
    # being reentrant lets callers that already hold it (Status#json_payload)
    # re-enter without deadlock, and `Task.new` (a widely-reused constructor)
    # needs no caller-side lock.
    def resolve_workflow
      if meta[:workflow_commit] || meta[:workflow_manifest_digest] || meta[:workflow_configuration_digest]
        unless meta[:workflow] && meta[:workflow_commit] && meta[:workflow_manifest_digest]
          raise InvalidTaskPath, "managed workflow task provenance is incomplete"
        end
        store = Hive::WorkflowPackage::ManagedStore.new(@hive_state_path)
        begin
          return store.workflow(
            meta[:workflow], meta[:workflow_commit], meta[:workflow_manifest_digest],
            configuration_digest: meta[:workflow_configuration_digest],
            cfg: @workflow_generation&.config || Hive::Config.load(@project_root)
          )
        rescue Hive::UnsupportedProjectConfigError
          raise
        rescue Hive::ConfigError => e
          raise InvalidTaskPath, e.message
        end
      end

      Hive::Workflows::Project.synchronize do
        Hive::Workflows::Project.load!(@project_root) unless @workflow_generation
        selector = meta[:workflow]
        # TaskMeta.read normalizes blank → nil, so a missing/blank selector is
        # always nil here (no .empty? branch needed).
        if selector.nil? && @workflow_generation
          selector = @workflow_generation.default_workflow
        end
        selector ||= project_default_workflow
        # A per-task `workflow:` pin to a descriptor that was SKIPPED at load
        # (bad YAML, invalid stage, id collision) must surface its REAL
        # ConfigError instead of a misleading UnknownWorkflow — the same
        # boundary rule the `--workflow` / `hive init` path uses (U9-3). Scoped
        # to the explicit pin; a typo'd project default keeps its
        # warn-and-continue behavior (warn_if_unregistered_project_default).
        unless @workflow_generation
          Hive::Workflows::Project.assert_descriptor_loadable!(
            meta[:workflow]&.to_sym, project_root: @project_root
          )
        end
        @workflow_generation ? @workflow_generation.fetch(selector) : Hive::Workflows::Registry.fetch(selector.to_sym)
      end
    rescue Hive::Workflows::UnknownWorkflow => e
      raise InvalidTaskPath, e.message
    end

    def project_default_workflow
      config_path = File.join(@hive_state_path, "config.yml")
      # The digest closes the same-size + preserved/coarse-mtime rewrite window.
      # Status captures this once per refresh, so ordinary scans do not pay this
      # read once per task.
      stamp = begin
        stat = File.stat(config_path)
        [ stat.mtime, stat.size, Digest::SHA256.file(config_path).hexdigest ]
      rescue SystemCallError
        nil
      end
      cache = Hive::Task.project_default_workflow_cache
      cached = cache[config_path]
      return cached[:value] if cached && cached[:stamp] == stamp

      value = load_project_default_workflow(config_path)
      cache[config_path] = { stamp: stamp, value: value }
      value
    end

    def load_project_default_workflow(config_path)
      configured = Hive::Config.load(@project_root)["default_workflow"].to_s.strip
      return Hive::Config::DEFAULTS["default_workflow"] if configured.empty?

      warn_if_unregistered_project_default(configured)
      configured
    rescue Hive::UnsupportedProjectConfigError
      raise
    rescue Hive::ConfigError, Psych::Exception, SystemCallError, IOError => e
      warn "hive: task: failed to read default_workflow from #{config_path} " \
           "(#{e.class}: #{e.message}); falling back to #{Hive::Config::DEFAULTS["default_workflow"]}"
      Hive::Config::DEFAULTS["default_workflow"]
    end

    # D1 still fails loud — resolve_workflow re-raises UnknownWorkflow as
    # InvalidTaskPath — so this returns the configured value verbatim. But unlike
    # a per-task `workflow:` selector, whose typo skips just that one task out of
    # `hive status` (and is rescued by Status#collect_rows), a typo'd PROJECT
    # default skips EVERY field-less task and silently empties the whole project
    # (the daemon then sees nothing to dispatch). Warn so that whole-project blast
    # radius is observable; resolution still raises afterwards.
    def warn_if_unregistered_project_default(name)
      Hive::Workflows::Registry.fetch(name.to_sym)
    rescue Hive::Workflows::UnknownWorkflow
      warn "hive: task: project default_workflow #{name.inspect} in " \
           "#{File.join(@hive_state_path, "config.yml")} is not a registered workflow; " \
           "every field-less task in this project will fail to load until it is fixed"
    end

    # Takes the resolved workflow explicitly (rather than reading @workflow) so
    # the dependency on resolve_workflow having run first is visible at the call
    # site, not an implicit ctor-ordering invariant.
    def validate_workflow_stage!(stage_dir, workflow)
      stage = workflow.stage_named(@stage_name)
      # A workflow repin changes policy resolution, not the task's existing
      # filesystem/archive membership. Retain the descriptor whose exact
      # terminal directory owns the folder solely for action/state-file
      # classification; `workflow` remains the newly pinned policy source.
      membership_candidates = membership_workflows.select do |candidate|
        candidate.stages.last.dir == stage_dir
      end
      unless membership_candidates.empty?
        evidenced = membership_candidates.select do |candidate|
          File.file?(File.join(@folder, candidate.stages.last.state_file))
        end
        if workflow.stages.last.dir == stage_dir
          membership_candidates = evidenced unless evidenced.empty?
          return membership_candidates.min_by { |candidate| candidate.id.to_s } if
            completed_at || evidenced.any?

          return workflow
        end

        if stage&.dir == stage_dir && completed_at.nil?
          distinct_evidence = evidenced.reject do |candidate|
            candidate.stages.last.state_file == stage.state_file
          end
          return workflow if distinct_evidence.empty?

          evidenced = distinct_evidence
        end
        membership_candidates = evidenced unless evidenced.empty?
        return membership_candidates.min_by { |candidate| candidate.id.to_s }
      end

      return workflow if stage&.dir == stage_dir

      if stage
        raise InvalidTaskPath,
              "stage directory #{stage_dir} does not match workflow #{workflow.id.inspect}; expected #{stage.dir}"
      end

      raise InvalidTaskPath,
            "unknown stage name: #{stage_dir} for workflow #{workflow.id.inspect}; " \
              "run `hive migrate` if this task uses pre-open-pr stage names"
    end

    def membership_workflows
      return @workflow_generation.workflows.values if @workflow_generation

      Hive::Workflows::Registry.all
    end
  end
end
