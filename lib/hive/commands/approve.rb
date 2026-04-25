require "fileutils"
require "json"
require "open3"
require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/lock"
require "hive/git_ops"

module Hive
  module Commands
    # Move a task folder between stages and record a hive/state commit. The
    # agent-callable replacement for shell `mv <task> <next-stage>/`.
    #
    # Two resolution paths for `target`:
    #   - absolute or relative folder path → used directly
    #   - bare slug → searched across registered projects (or the one given
    #     by --project) for an unambiguous match
    #
    # Forward auto-advance requires a terminal marker (`:complete` /
    # `:execute_complete`). Explicit `--to <stage>` overrides — useful for
    # recovery flows like moving 4-execute back to 3-plan.
    class Approve
      VALID_TERMINAL_MARKERS = %i[complete execute_complete].freeze
      STAGE_NAMES = %w[1-inbox 2-brainstorm 3-plan 4-execute 5-pr 6-done].freeze
      STAGE_BY_NAME = STAGE_NAMES.each_with_object({}) { |s, h| h[s.split("-", 2).last] = s }.freeze

      def initialize(target, to: nil, project: nil, force: false, json: false)
        @target = target
        @to = to
        @project_filter = project
        @force = force
        @json = json
      end

      def call
        folder = resolve_target
        task = Hive::Task.new(folder)
        next_stage_dir = resolve_destination(task)
        validate_move!(task, next_stage_dir)

        new_folder = move_task!(task, next_stage_dir)
        commit_action = "approve #{task.stage_index}-#{task.stage_name} -> #{next_stage_dir}"
        record_hive_commit(task, next_stage_dir, commit_action)

        emit_report(task, next_stage_dir, new_folder, commit_action)
      end

      private

      def resolve_target
        expanded = File.expand_path(@target)
        return expanded if File.directory?(expanded)

        matches = find_slug_across_projects(@target)
        case matches.size
        when 0
          raise Hive::InvalidTaskPath,
                "no task folder for slug '#{@target}'#{project_hint}"
        when 1
          matches.first
        else
          project_names = matches.map { |p| File.basename(p.split("/.hive-state/").first) }.uniq
          raise Hive::InvalidTaskPath,
                "slug '#{@target}' is ambiguous (in #{project_names.join(', ')}); pass --project <name>"
        end
      end

      def project_hint
        @project_filter ? " in project '#{@project_filter}'" : ""
      end

      # When a slug appears in multiple stages of the same project (typically
      # a stale leftover from a failed move), prefer the lowest stage index —
      # that's almost always the "real" task. Cross-project ambiguity still
      # requires --project; same-project picks deterministically.
      def find_slug_across_projects(slug)
        projects = Hive::Config.registered_projects
        projects = projects.select { |p| p["name"] == @project_filter } if @project_filter
        per_project = projects.map do |project|
          hits = STAGE_NAMES
                 .map { |stage| File.join(project["hive_state_path"], "stages", stage, slug) }
                 .select { |p| File.directory?(p) }
          hits.first
        end
        per_project.compact
      end

      # Returns the destination stage directory name (e.g. "3-plan").
      def resolve_destination(task)
        return resolve_explicit_to(@to) if @to

        next_idx = task.stage_index + 1
        STAGE_NAMES.find { |s| s.start_with?("#{next_idx}-") } ||
          raise(Hive::Error, "task is already at the final stage (#{task.stage_index}-#{task.stage_name})")
      end

      def resolve_explicit_to(to)
        # Accept either "3-plan" or "plan".
        return to if STAGE_NAMES.include?(to)

        STAGE_BY_NAME.fetch(to) do
          raise Hive::InvalidTaskPath,
                "unknown stage '#{to}'; valid: #{STAGE_NAMES.join(', ')} or short names #{STAGE_BY_NAME.keys.join(', ')}"
        end
      end

      def validate_move!(task, dest_stage)
        # Backward / explicit moves bypass the terminal-marker requirement;
        # they are deliberate recovery actions.
        dest_idx = dest_stage.split("-", 2).first.to_i
        return if dest_idx <= task.stage_index || @force

        marker = Hive::Markers.current(task.state_file)
        return if VALID_TERMINAL_MARKERS.include?(marker.name)

        raise Hive::WrongStage,
              "task #{task.slug} marker is :#{marker.name}; forward approve requires a terminal marker " \
              "(:complete or :execute_complete). Use --force to override or --to to move backward."
      end

      def move_task!(task, dest_stage)
        new_parent = File.join(task.hive_state_path, "stages", dest_stage)
        FileUtils.mkdir_p(new_parent)
        new_folder = File.join(new_parent, task.slug)

        if File.directory?(new_folder)
          raise Hive::Error,
                "destination already exists: #{new_folder} (slug collision; archive or rename the existing folder)"
        end

        FileUtils.mv(task.folder, new_folder)
        new_folder
      end

      # Custom commit path (rather than GitOps#hive_commit) because the move
      # needs `git add -A` over BOTH source and destination *parent stage
      # directories* — the source path itself is gone after the move so
      # `git add -A <missing-path>` would error, but adding the parent stage
      # dir always works and records both the deletion and the new content.
      # Whether the original was tracked or untracked, this lands correctly.
      def record_hive_commit(task, dest_stage, action)
        message = "hive: #{task.stage_index}-#{task.stage_name}/#{task.slug} #{action}"
        ops = Hive::GitOps.new(task.project_root)
        source_stage_rel = File.join("stages", "#{task.stage_index}-#{task.stage_name}")
        dest_stage_rel = File.join("stages", dest_stage)
        Hive::Lock.with_commit_lock(task.hive_state_path) do
          ops.run_git!("-C", task.hive_state_path, "add", "-A", source_stage_rel, dest_stage_rel)
          _, _, status = Open3.capture3("git", "-C", task.hive_state_path, "diff", "--cached", "--quiet")
          ops.run_git!("-C", task.hive_state_path, "commit", "-m", message) unless status.success?
        end
      end

      def emit_report(task, dest_stage, new_folder, commit_action)
        if @json
          puts JSON.generate(
            "schema" => "hive-approve",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-approve"),
            "slug" => task.slug,
            "from_stage" => "#{task.stage_index}-#{task.stage_name}",
            "to_stage" => dest_stage,
            "from_folder" => task.folder,
            "to_folder" => new_folder,
            "commit_action" => commit_action
          )
        else
          puts "hive: approved #{task.slug}"
          puts "  from: #{task.folder}"
          puts "  to:   #{new_folder}"
          puts "next: hive run #{new_folder}"
        end
      end
    end
  end
end
