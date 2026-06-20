require "yaml"
require "hive/config"
require "hive/stages"
require "hive/task_meta"
require "hive/workflows/registry"
require "hive/worktree"

module Hive
  class Task
    # Coding-default only: pinned to Registry.default. Prefer the
    # descriptor-driven Task#stage_names instance accessor for workflow-aware
    # callers — these constants diverge for non-coding workflows (full consumer
    # migration is U6).
    STAGE_NAMES = Hive::Workflows::Registry.default.stages.map(&:name).freeze
    STATE_FILES = Hive::Workflows::Registry.default.stages.to_h { |stage| [ stage.name, stage.state_file ] }.freeze
    PATH_RE = %r{\A(?<root>.+)/(?<state_dir>\.hive-state)/stages/(?<stage_dir>(?<stage_idx>\d+)-(?<stage_name>[a-z][a-z0-9-]*))/(?<slug>[a-z][a-z0-9-]{0,62}[a-z0-9])/?\z}

    attr_reader :folder, :project_root, :hive_state_path, :stage_index,
                :stage_name, :slug, :state_dir_basename, :workflow

    def initialize(folder)
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
      @workflow = resolve_workflow
      validate_workflow_stage!(m[:stage_dir])
    end

    def project_name
      File.basename(@project_root)
    end

    def state_file
      File.join(@folder, workflow.state_file_for(@stage_name))
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

    def display_label
      display_name || slug
    end

    def worktree_path
      # Worktree first appears in 4-execute and carries through open-pr,
      # review, artifacts, and finalize; earlier stages don't have one. 9-done is post-PR; the
      # worktree may still exist (cleanup happens after merge).
      return nil if @stage_index < 4

      if File.exist?(worktree_yml_path)
        data = YAML.safe_load(File.read(worktree_yml_path)) || {}
        return data["path"] if data.is_a?(Hash) && data["path"]
      end
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

    def resolve_workflow
      selector = meta[:workflow]
      # TaskMeta.read normalizes blank → nil, so a missing/blank selector is
      # always nil here (no .empty? branch needed).
      selector ||= project_default_workflow
      Hive::Workflows::Registry.fetch(selector.to_sym)
    rescue Hive::Workflows::UnknownWorkflow => e
      raise InvalidTaskPath, e.message
    end

    def project_default_workflow
      configured = Hive::Config.load(@project_root)["default_workflow"].to_s.strip
      configured.empty? ? Hive::Config::DEFAULTS["default_workflow"] : configured
    rescue Hive::ConfigError, Psych::Exception, SystemCallError, IOError => e
      warn "hive: task: failed to read default_workflow from #{File.join(@hive_state_path, "config.yml")} " \
           "(#{e.class}: #{e.message}); falling back to #{Hive::Config::DEFAULTS["default_workflow"]}"
      Hive::Config::DEFAULTS["default_workflow"]
    end

    def validate_workflow_stage!(stage_dir)
      stage = workflow.stage_named(@stage_name)
      unless stage
        raise InvalidTaskPath,
              "unknown stage name: #{stage_dir} for workflow #{workflow.id.inspect}; " \
              "run `hive migrate` if this task uses pre-open-pr stage names"
      end
      return if stage.dir == stage_dir

      raise InvalidTaskPath,
            "stage directory #{stage_dir} does not match workflow #{workflow.id.inspect}; expected #{stage.dir}"
    end
  end
end
