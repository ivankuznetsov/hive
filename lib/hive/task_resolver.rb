require "hive/config"
require "hive/task"
require "hive/task_meta"
require "hive/stages"
require "hive/workflows"
require "hive/workflows/project"

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
      @stage_filter = stage_filter
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

      return resolve_numeric_id if numeric_target?

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

    def numeric_target?
      @target.to_s.match?(/\A\d+\z/)
    end

    def resolve_numeric_id
      matches = find_id_across_projects(Integer(@target))
      case matches.size
      when 0
        raise Hive::InvalidTaskPath,
              "no task folder for id #{@target}#{project_hint}"
      when 1
        File.realpath(matches.first[:folder])
      else
        raise Hive::AmbiguousSlug.new(
          id_ambiguity_message(matches),
          slug: @target,
          candidates: matches
        )
      end
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

    def id_ambiguity_message(matches)
      labels = matches.map { |m| "#{m[:project]}/#{m[:stage]}/#{File.basename(m[:folder])}" }.join(", ")
      "task id #{@target} is duplicated (#{labels}); repair duplicate meta.yml ids"
    end

    def find_slug_across_projects(slug)
      projects = Hive::Config.registered_projects
      projects = projects.select { |p| p["name"] == @project_filter } if @project_filter
      projects.flat_map do |project|
        stages = stages_for_project(project)
        stages.filter_map do |stage|
          folder = File.join(project["hive_state_path"], "stages", stage, slug)
          next nil unless File.directory?(folder)

          { project: project["name"], stage: stage, folder: folder }
        end
      end
    end

    def find_id_across_projects(id)
      projects = Hive::Config.registered_projects
      projects = projects.select { |p| p["name"] == @project_filter } if @project_filter
      projects.flat_map do |project|
        stages = stages_for_project(project)
        stages.flat_map do |stage|
          stage_dir = File.join(project["hive_state_path"], "stages", stage)
          next [] unless File.directory?(stage_dir)

          Dir.children(stage_dir).sort.filter_map do |entry|
            folder = File.join(stage_dir, entry)
            next unless File.directory?(folder)
            next unless Hive::TaskMeta.read(folder)[:id] == id

            { project: project["name"], stage: stage, folder: folder }
          end
        end
      end
    end

    def stages_for_project(project)
      Hive::Workflows::Project.load!(project["path"])
      return Hive::Workflows.all_stage_dirs unless @stage_filter

      [ Hive::Workflows.resolve_stage_ref_across_workflows(@stage_filter) ]
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
      expected = task.workflow.resolve_stage_ref(@stage_filter) || @stage_filter
      return if actual == expected

      raise Hive::InvalidTaskPath,
            "TARGET is at #{actual} but --stage/--from says #{expected}"
    end
  end
end
