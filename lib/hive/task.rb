require "yaml"

module Hive
  class Task
    STAGE_NAMES = %w[inbox brainstorm plan execute review pr done].freeze
    STATE_FILES = {
      "inbox" => "idea.md",
      "brainstorm" => "brainstorm.md",
      "plan" => "plan.md",
      "execute" => "task.md",
      "review" => "task.md",
      "pr" => "pr.md",
      "done" => "task.md"
    }.freeze
    PATH_RE = %r{\A(?<root>.+)/(?<state_dir>\.hive-state)/stages/(?<stage_idx>\d+)-(?<stage_name>\w+)/(?<slug>[a-z][a-z0-9-]{0,62}[a-z0-9])/?\z}

    attr_reader :folder, :project_root, :hive_state_path, :stage_index,
                :stage_name, :slug, :state_dir_basename

    def initialize(folder)
      folder = File.expand_path(folder)
      m = PATH_RE.match(folder)
      raise InvalidTaskPath, "task path must match <project>/.hive-state/stages/<N>-<name>/<slug>/: #{folder}" unless m
      raise InvalidTaskPath, "unknown stage name: #{m[:stage_name]}" unless STAGE_NAMES.include?(m[:stage_name])

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

    def worktree_path
      # Worktree first appears in 4-execute and carries through 5-review
      # and 6-pr; earlier stages don't have one. 7-done is post-PR; the
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
      template = cfg["worktree_root"] || File.expand_path("~/Dev/#{project_name}.worktrees")
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
  end
end
