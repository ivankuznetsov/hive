require "yaml"
require "hive/stages"
require "hive/task_meta"
require "hive/worktree"

module Hive
  class Task
    STAGE_NAMES = %w[inbox brainstorm plan execute open-pr review artifacts finalize done].freeze
    STATE_FILES = {
      "inbox" => "idea.md",
      "brainstorm" => "brainstorm.md",
      "plan" => "plan.md",
      "execute" => "task.md",
      "open-pr" => "pr.md",
      "review" => "task.md",
      "artifacts" => "artifact.md",
      "finalize" => "pr.md",
      "done" => "task.md"
    }.freeze
    PATH_RE = %r{\A(?<root>.+)/(?<state_dir>\.hive-state)/stages/(?<stage_idx>\d+)-(?<stage_name>[a-z][a-z0-9-]*)/(?<slug>[a-z][a-z0-9-]{0,62}[a-z0-9])/?\z}

    attr_reader :folder, :project_root, :hive_state_path, :stage_index,
                :stage_name, :slug, :state_dir_basename

    def initialize(folder)
      folder = File.expand_path(folder)
      m = PATH_RE.match(folder)
      raise InvalidTaskPath, "task path must match <project>/.hive-state/stages/<N>-<name>/<slug>/: #{folder}" unless m
      stage_dir = "#{m[:stage_idx]}-#{m[:stage_name]}"
      unless STAGE_NAMES.include?(m[:stage_name]) && Hive::Stages.parse(stage_dir)
        raise InvalidTaskPath, "unknown stage name: #{stage_dir}; run `hive migrate` if this task uses pre-open-pr stage names"
      end

      @folder = folder.sub(%r{/\z}, "")
      @project_root = m[:root]
      @state_dir_basename = m[:state_dir]
      @hive_state_path = File.join(@project_root, m[:state_dir])
      @stage_index = m[:stage_idx].to_i
      @stage_name = m[:stage_name]
      @slug = m[:slug]
    end

    def project_name
      File.basename(@project_root)
    end

    def state_file
      File.join(@folder, STATE_FILES.fetch(@stage_name))
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
  end
end
