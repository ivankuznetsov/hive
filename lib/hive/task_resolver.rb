require "hive/config"
require "hive/task"
require "hive/task_meta"
require "hive/stages"
require "hive/workflows"
require "hive/workflows/project"

module Hive
  # Resolve a CLI TARGET (folder path, bare slug, or numeric task id) to a
  # `Hive::Task`. Shared between the agent-callable commands (`approve`,
  # `findings`, `accept-finding`, `reject-finding`, and `drop` for its numeric-id
  # targets) so the slug-lookup, numeric-id, ambiguity, realpath, and `--project`
  # mismatch rules are defined in one place.
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
        # A `--from`/`--stage` filter unknown in EVERY project is a usage error;
        # surface "unknown stage '<x>'" rather than the generic missing-slug
        # message (stages_for_project tolerates a per-project mismatch).
        Hive::Workflows.assert_known_stage_filter!(@stage_filter, filtered_projects)
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

    # Mirrors Hive::Commands::Drop#numeric_target? — keep this /\A\d+\z/ rule in
    # lockstep with that one (Drop routes onto the resolver path before it can
    # reach this method, so the predicate is duplicated rather than shared).
    def numeric_target?
      @target.to_s.match?(/\A\d+\z/)
    end

    def resolve_numeric_id
      matches = find_id_across_projects(Integer(@target))
      case matches.size
      when 0
        Hive::Workflows.assert_known_stage_filter!(@stage_filter, filtered_projects)
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

    # The " in project 'X' and stage 'Y'" tail appended to a not-found error.
    # Extracted as a class method so Hive::Commands::Drop (which builds the
    # identical string from @from == @stage_filter) shares one formatter and the
    # two can't drift apart.
    def self.project_hint(project_filter:, stage_filter:)
      hints = []
      hints << "project '#{project_filter}'" if project_filter
      hints << "stage '#{stage_filter}'" if stage_filter
      hints.empty? ? "" : " in #{hints.join(' and ')}"
    end

    def project_hint
      self.class.project_hint(project_filter: @project_filter, stage_filter: @stage_filter)
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

    # Registered projects, narrowed to `--project` when set. Single source for
    # the slug/id scans and the unknown-stage-filter guard so they iterate the
    # identical set.
    def filtered_projects
      projects = Hive::Config.registered_projects
      @project_filter ? projects.select { |p| p["name"] == @project_filter } : projects
    end

    def find_slug_across_projects(slug)
      filtered_projects.flat_map do |project|
        stages = Hive::Workflows.stages_for_project(project, stage_filter: @stage_filter)
        stages.filter_map do |stage|
          folder = File.join(project["hive_state_path"], "stages", stage, slug)
          next nil unless File.directory?(folder)

          { project: project["name"], stage: stage, folder: folder }
        end
      end
    end

    def find_id_across_projects(id)
      filtered_projects.flat_map do |project|
        stages = Hive::Workflows.stages_for_project(project, stage_filter: @stage_filter)
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
