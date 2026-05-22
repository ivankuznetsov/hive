require "fileutils"
require "json"
require "yaml"
require "hive/config"
require "hive/task"
require "hive/task_resolver"
require "hive/markers"
require "hive/git_ops"
require "hive/gh"
require "hive/lock"
require "hive/process_kill"
require "hive/stages"
require "hive/worktree"

module Hive
  module Commands
    # `hive drop TARGET` — hard-delete an active task from Hive state and
    # the associated project worktree/branch. This is intentionally not
    # an archive: no dropped bucket, no undo, no reason prompt.
    class Drop
      include Hive::Schemas::EnvelopeEmitter

      ACTIVE_STAGE_DIRS = Hive::Stages::DIRS.reject { |stage| stage == "9-done" }.freeze

      AlreadyArchived = Class.new(Hive::InvalidTaskPath)

      TaskContext = Struct.new(
        :slug, :project_name, :project_root, :hive_state_path, :folders,
        :from_stages, keyword_init: true
      )

      def initialize(target, project: nil, from: nil, json: false)
        @target = target
        @project_filter = project
        @from = from
        @stage_filter = resolve_stage_filter(from)
        @json = json
      end

      def call
        call_with_envelope { do_call }
      end

      def envelope_schema
        "hive-drop"
      end

      def envelope_error_kind(error)
        error_kind_for(error)
      end

      def do_call
        context = resolve_context
        guard_archived!(context)

        cleanup = cleanup_context(context)
        commit_action = record_drop_commit!(context)

        payload = success_payload(context, cleanup, commit_action)
        if @json
          puts JSON.generate(payload)
          @stdout_written = true
        else
          puts "dropped #{context.slug} from #{context.project_name} (#{context.from_stages.join(', ')})"
        end
      end

      private

      def resolve_context
        path_target? ? resolve_path_context : resolve_slug_context
      end

      def path_target?
        @target.to_s.include?("/") || @target.to_s.start_with?("~", ".")
      end

      def resolve_path_context
        task = Hive::TaskResolver.new(
          @target,
          project_filter: @project_filter,
          stage_filter: @stage_filter
        ).resolve
        project_name = project_name_for(task)
        folders = collect_stage_folders(task.hive_state_path, task.slug, ACTIVE_STAGE_DIRS)
        TaskContext.new(
          slug: task.slug,
          project_name: project_name,
          project_root: task.project_root,
          hive_state_path: task.hive_state_path,
          folders: folders,
          from_stages: folders.map { |f| f[:stage] }
        )
      end

      def resolve_slug_context
        projects = Hive::Config.registered_projects
        projects = projects.select { |p| p["name"] == @project_filter } if @project_filter
        matches_by_project = projects.filter_map do |project|
          stages = @stage_filter ? [ @stage_filter ] : Hive::Stages::DIRS
          folders = collect_stage_folders(project["hive_state_path"], @target, stages)
          next if folders.empty?

          [ project, folders ]
        end

        if matches_by_project.empty?
          raise_wrong_stage_if_slug_exists_elsewhere!
          raise Hive::InvalidTaskPath,
                "no task folder for slug '#{@target}'#{project_hint}"
        end
        if matches_by_project.size > 1
          raise Hive::AmbiguousSlug.new(
            "slug '#{@target}' is ambiguous (in #{matches_by_project.map { |project, _| project['name'] }.join(', ')}); pass --project <name>",
            slug: @target,
            candidates: matches_by_project.flat_map do |project, folders|
              folders.map { |folder| { project: project["name"], stage: folder[:stage], folder: folder[:folder] } }
            end
          )
        end

        project, folders = matches_by_project.first
        if @stage_filter.nil?
          active_folders = folders.reject { |f| f[:stage] == "9-done" }
          folders = active_folders unless active_folders.empty?
        end
        TaskContext.new(
          slug: @target,
          project_name: project["name"],
          project_root: project["path"],
          hive_state_path: project["hive_state_path"],
          folders: folders,
          from_stages: folders.map { |f| f[:stage] }
        )
      end

      def collect_stage_folders(hive_state_path, slug, stages)
        Array(stages).filter_map do |stage|
          folder = File.join(hive_state_path, "stages", stage, slug)
          next unless File.directory?(folder)

          { stage: stage, folder: File.realpath(folder) }
        end
      end

      def raise_wrong_stage_if_slug_exists_elsewhere!
        return unless @stage_filter

        projects = Hive::Config.registered_projects
        projects = projects.select { |p| p["name"] == @project_filter } if @project_filter
        all_matches = projects.flat_map do |project|
          collect_stage_folders(project["hive_state_path"], @target, Hive::Stages::DIRS).map do |folder|
            [ project, folder ]
          end
        end
        return if all_matches.empty? || all_matches.map { |project, _| project["name"] }.uniq.size > 1

        actual_stage = all_matches.first[1][:stage]
        raise Hive::WrongStage.new(
          "task is at #{actual_stage} but --from expected #{@stage_filter}",
          current_stage: actual_stage,
          target_stage: @stage_filter
        )
      end

      def project_name_for(task)
        match = Hive::Config.registered_projects.find { |p| p["path"] == task.project_root }
        match ? match["name"] : task.project_name
      end

      def project_hint
        hints = []
        hints << "project '#{@project_filter}'" if @project_filter
        hints << "stage '#{@stage_filter}'" if @stage_filter
        hints.empty? ? "" : " in #{hints.join(' and ')}"
      end

      def resolve_stage_filter(stage)
        return nil if stage.nil? || stage.to_s.strip.empty?

        Hive::Stages.resolve(stage) ||
          raise(Hive::InvalidTaskPath,
                "unknown stage '#{stage}'; valid: #{Hive::Stages::DIRS.join(', ')} " \
                "or short names #{Hive::Stages::NAMES.join(', ')}")
      end

      def guard_archived!(context)
        return unless context.folders.all? { |f| f[:stage] == "9-done" }

        raise AlreadyArchived, "task #{context.slug} is at 9-done; nothing to drop"
      end

      def cleanup_context(context)
        folders = context.folders
        killed = kill_recorded_agents(folders)
        pr_closed = close_draft_prs(folders)
        worktree_removed = remove_worktrees(context, folders)
        branch_deleted = delete_branch(context)
        remove_task_folders(context)
        FileUtils.rm_rf(File.join(context.hive_state_path, "logs", context.slug))

        {
          agent: killed,
          pr_closed: pr_closed,
          worktree_removed: worktree_removed,
          branch_deleted: branch_deleted
        }
      end

      def kill_recorded_agents(folders)
        candidates = process_candidates(folders)
        return { killed: false, pid: nil, killed_pids: [], skipped_reason: "no_pid" } if candidates.empty?

        killed_pids = []
        skipped_reasons = []
        candidates.each do |candidate|
          result =
            if candidate[:group]
              Hive::ProcessKill.terminate_process_group(
                candidate[:pid],
                recorded_start_time: candidate[:process_start_time]
              )
            else
              Hive::ProcessKill.terminate_process(
                candidate[:pid],
                recorded_start_time: candidate[:process_start_time]
              )
            end
          killed_pids << result.pid if result.killed && result.pid
          skipped_reasons << result.skipped_reason if result.skipped_reason
        end

        {
          killed: !killed_pids.empty?,
          pid: candidates.first[:pid],
          killed_pids: killed_pids.uniq,
          skipped_reason: killed_pids.empty? ? skipped_reasons.compact.first : nil
        }
      end

      def process_candidates(folders)
        by_pid = {}
        folders.each do |entry|
          lock = lock_payload(File.join(entry[:folder], ".lock"))
          if integer_like?(lock["claude_pid"])
            by_pid[lock["claude_pid"].to_i] = {
              pid: lock["claude_pid"].to_i,
              process_start_time: nil,
              group: true
            }
          end
          if integer_like?(lock["pid"])
            by_pid[lock["pid"].to_i] = {
              pid: lock["pid"].to_i,
              process_start_time: lock["process_start_time"],
              group: false
            }
          end

          marker = marker_for(entry[:folder])
          marker_pid = marker.attrs["pid"]
          next unless marker.name == :agent_working && integer_like?(marker_pid)

          by_pid[marker_pid.to_i] ||= {
            pid: marker_pid.to_i,
            process_start_time: lock["pid"].to_i == marker_pid.to_i ? lock["process_start_time"] : nil,
            group: false
          }
        end
        by_pid.values
      end

      def lock_payload(path)
        return {} unless File.exist?(path)

        data = YAML.safe_load(File.read(path), permitted_classes: [ Time ]) || {}
        data.is_a?(Hash) ? data : {}
      rescue Psych::Exception, SystemCallError, IOError
        {}
      end

      def marker_for(folder)
        state_file = state_file_for_folder(folder)
        Hive::Markers.current(state_file)
      rescue Hive::InvalidTaskPath, SystemCallError, IOError
        Hive::Markers::State.new(name: :none, attrs: {}, raw: nil)
      end

      def state_file_for_folder(folder)
        Hive::Task.new(folder).state_file
      end

      def integer_like?(value)
        value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)
      end

      def close_draft_prs(folders)
        urls = folders.filter_map do |entry|
          frontmatter = Hive::Gh.pr_frontmatter(File.join(entry[:folder], "pr.md"))
          frontmatter["pr_url"].to_s.strip.empty? ? nil : frontmatter["pr_url"].to_s.strip
        end.uniq
        return false if urls.empty?

        closed_any = false
        urls.each do |url|
          out, err, status = Hive::Gh.capture3("gh", "pr", "close", url, "--comment", "task dropped")
          if status.success?
            closed_any = true
          else
            warn "[hive] drop: gh pr close #{url} failed: #{err.to_s.strip.empty? ? out : err}"
          end
        rescue Hive::GhError => e
          warn "[hive] drop: gh pr close skipped: #{e.message}"
        end
        closed_any
      end

      def remove_worktrees(context, folders)
        paths = worktree_paths(context, folders)
        return false if paths.empty?

        removed = false
        wt = Hive::Worktree.new(context.project_root, context.slug)
        paths.each do |path|
          removed = remove_one_worktree(wt, path) || removed
        end
        Hive::GitOps.new(context.project_root).prune_worktrees!
        removed
      end

      def remove_one_worktree(wt, path)
        return false unless File.directory?(path) || wt.list_worktree_paths.include?(path)

        begin
          wt.remove!(path: path)
        rescue Hive::WorktreeError => e
          begin
            wt.remove_force!(path: path)
          rescue Hive::WorktreeError => force_error
            return false if !File.directory?(path) &&
                            e.message.start_with?("git worktree remove failed")

            raise force_error
          end
        end
        true
      end

      def worktree_paths(context, folders)
        paths = folders.filter_map do |entry|
          pointer = Hive::Worktree.read_pointer(entry[:folder])
          pointer && pointer["path"]
        rescue Hive::WorktreeError
          nil
        end
        paths << Hive::Worktree.new(context.project_root, context.slug).path
        paths.compact.map { |path| File.expand_path(path) }.uniq
      end

      def delete_branch(context)
        Hive::GitOps.new(context.project_root).delete_branch!(context.slug)
      end

      def remove_task_folders(context)
        ACTIVE_STAGE_DIRS.each do |stage|
          FileUtils.rm_rf(File.join(context.hive_state_path, "stages", stage, context.slug))
        end
      end

      def record_drop_commit!(context)
        rel_paths = context.from_stages.map { |stage| File.join("stages", stage, context.slug) }
        rel_paths << File.join("logs", context.slug)
        body = "Dropped task #{context.slug} from stages: #{context.from_stages.join(', ')}"
        Hive::Lock.with_commit_lock(context.hive_state_path) do
          Hive::GitOps.new(context.project_root).hive_commit(
            stage_name: "dropped",
            slug: context.slug,
            action: "dropped",
            body: body,
            pathspecs: rel_paths,
            allow_empty: true
          )
        end
        "dropped"
      end

      def success_payload(context, cleanup, commit_action)
        agent = cleanup.fetch(:agent)
        {
          "schema" => "hive-drop",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-drop"),
          "ok" => true,
          "slug" => context.slug,
          "project" => context.project_name.to_s,
          "from_stages" => context.from_stages,
          "pr_closed" => cleanup.fetch(:pr_closed),
          "worktree_removed" => cleanup.fetch(:worktree_removed),
          "branch_deleted" => cleanup.fetch(:branch_deleted),
          "agent_killed" => agent.fetch(:killed),
          "agent_pid" => agent.fetch(:pid),
          "agent_killed_pids" => agent.fetch(:killed_pids),
          "agent_kill_skipped_reason" => agent.fetch(:skipped_reason),
          "commit_action" => commit_action
        }
      end

      def error_kind_for(error)
        case error
        when AlreadyArchived         then Hive::Schemas::DropErrorKind::ALREADY_ARCHIVED
        when Hive::AmbiguousSlug     then Hive::Schemas::DropErrorKind::AMBIGUOUS_SLUG
        when Hive::WrongStage        then Hive::Schemas::DropErrorKind::WRONG_STAGE
        when Hive::InvalidTaskPath   then Hive::Schemas::DropErrorKind::INVALID_TASK_PATH
        when Hive::ConfigError       then Hive::Schemas::DropErrorKind::CONFIG
        when Hive::GitError          then Hive::Schemas::DropErrorKind::GIT
        when Hive::WorktreeError     then Hive::Schemas::DropErrorKind::WORKTREE
        when Hive::InternalError     then Hive::Schemas::DropErrorKind::INTERNAL
        else                              Hive::Schemas::DropErrorKind::ERROR
        end
      end
    end
  end
end
