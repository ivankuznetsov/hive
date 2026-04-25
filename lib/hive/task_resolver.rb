require "hive/config"
require "hive/task"
require "hive/stages"

module Hive
  # Resolve a CLI TARGET (folder path or bare slug) to a `Hive::Task`.
  # Shared between the agent-callable commands (`approve`, `findings`,
  # `accept-finding`, `reject-finding`) so the slug-lookup, ambiguity,
  # realpath, and `--project` mismatch rules are defined in one place.
  #
  # Resolution rules:
  #   - path-shaped (`/`, `~/`, `./`) → expanded + realpath'd; refused if
  #     not a directory OR if the realpath leaves the .hive-state tree.
  #   - bare slug → searched across registered projects (filtered by
  #     `--project` if given). Multi-stage hits within one project are
  #     ambiguous; cross-project hits are ambiguous unless `--project` is
  #     set. `stage_filter` narrows slug lookup to one canonical stage.
  class TaskResolver
    def initialize(target, project_filter: nil, stage_filter: nil)
      @target = target
      @project_filter = project_filter
      @stage_filter = resolve_stage_filter(stage_filter)
    end

    def resolve
      folder = resolve_folder
      task = Hive::Task.new(folder)
      validate_project_path_match!(task)
      validate_stage_match!(task)
      task
    end

    private

    def resolve_folder
      if path_target?
        expanded = File.expand_path(@target)
        return File.realpath(expanded) if File.directory?(expanded)
      end

      matches = find_slug_across_projects(@target)
      case matches.size
      when 0
        raise Hive::InvalidTaskPath,
              "no task folder for slug '#{@target}'#{project_hint}"
      when 1
        File.realpath(matches.first[:folder])
      else
        raise Hive::AmbiguousSlug.new(
          ambiguity_message(matches),
          slug: @target,
          candidates: matches
        )
      end
    end

    def path_target?
      @target.include?("/") || @target.start_with?("~", ".")
    end

    def project_hint
      hints = []
      hints << "project '#{@project_filter}'" if @project_filter
      hints << "stage '#{@stage_filter}'" if @stage_filter
      hints.empty? ? "" : " in #{hints.join(' and ')}"
    end

    def ambiguity_message(matches)
      projects = matches.map { |m| m[:project] }.uniq
      if projects.size > 1
        "slug '#{@target}' is ambiguous (in #{projects.join(', ')}); pass --project <name>"
      else
        stages = matches.map { |m| m[:stage] }
        "slug '#{@target}' is ambiguous (multiple stages in '#{projects.first}': #{stages.join(', ')}); " \
          "pass --stage <stage> or an absolute folder path"
      end
    end

    def find_slug_across_projects(slug)
      projects = Hive::Config.registered_projects
      projects = projects.select { |p| p["name"] == @project_filter } if @project_filter
      stages = @stage_filter ? [ @stage_filter ] : Hive::Stages::DIRS
      projects.flat_map do |project|
        stages.filter_map do |stage|
          folder = File.join(project["hive_state_path"], "stages", stage, slug)
          next nil unless File.directory?(folder)

          { project: project["name"], stage: stage, folder: folder }
        end
      end
    end

    def validate_project_path_match!(task)
      return unless @project_filter
      return unless path_target?

      matching = Hive::Config.registered_projects.find { |p| p["path"] == task.project_root }
      actual_name = matching ? matching["name"] : File.basename(task.project_root)
      return if actual_name == @project_filter

      raise Hive::InvalidTaskPath,
            "TARGET path is in project '#{actual_name}' but --project says '#{@project_filter}'"
    end

    def validate_stage_match!(task)
      return unless @stage_filter

      actual = "#{task.stage_index}-#{task.stage_name}"
      return if actual == @stage_filter

      raise Hive::InvalidTaskPath,
            "TARGET is at #{actual} but --stage/--from says #{@stage_filter}"
    end

    def resolve_stage_filter(stage_filter)
      return nil if stage_filter.nil? || stage_filter.to_s.strip.empty?

      Hive::Stages.resolve(stage_filter) ||
        raise(Hive::InvalidTaskPath,
              "unknown stage '#{stage_filter}'; valid: #{Hive::Stages::DIRS.join(', ')} " \
              "or short names #{Hive::Stages::NAMES.join(', ')}")
    end
  end
end
