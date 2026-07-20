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
require "hive/workflows"
require "hive/workflows/project"
require "hive/worktree"

module Hive
  module Commands
    # `hive drop TARGET` — hard-delete an active task from Hive state and
    # the associated project worktree/branch. This is intentionally not
    # an archive: no dropped bucket, no undo, no reason prompt.
    class Drop
      include Hive::Schemas::EnvelopeEmitter

      AlreadyArchived = Class.new(Hive::InvalidTaskPath)

      TaskContext = Struct.new(
        :slug, :project_name, :project_root, :hive_state_path, :folders,
        :from_stages, :archive_stage_dirs, keyword_init: true
      )

      # `from` accepts either the long stage dir ("4-execute") or the # not-a-stage-ref: CLI help example
      # short name ("execute"); see `Hive::Stages.resolve` for the map.
      def initialize(target, project: nil, from: nil, json: false, audit: nil)
        @target = target
        @project_filter = project
        @from = from
        @stage_filter = from
        @json = json
        @audit = audit&.transform_keys(&:to_s)
      end

      def call
        call_with_envelope { do_call }
      end

      # The web transition dispatcher owns the project commit lock so it can
      # compare the rendered fingerprint and exact transition immediately
      # before deletion. This primitive deliberately performs no nested lock.
      def call_under_lock
        call_with_envelope { perform_drop(resolve_context) }
      end

      def envelope_schema
        "hive-drop"
      end

      def envelope_error_kind(error)
        error_kind_for(error)
      end

      private

      def do_call
        owner = resolve_context
        Hive::Lock.with_commit_lock(owner.hive_state_path) do
          # The pre-lock resolve discovers the owner only. Resolve again under
          # the lock before any process, PR, worktree, branch, or folder is
          # touched so a concurrent stage move cannot pass a stale guard.
          perform_drop(resolve_context)
        end
      end

      def perform_drop(context)
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
        # Returned (not just printed) so in-process callers — the web tier —
        # can see partial-cleanup facts (pr_closed/branch_deleted/...) that
        # the CLI surfaces only as stderr warnings, which a Puma worker
        # would swallow.
        payload
      end

      def resolve_context
        (path_target? || numeric_target?) ? resolve_path_context : resolve_slug_context
      end

      # Slugs match Stages::SLUG_RE — any /, ~, or . means a path.
      # Windows \ unsupported.
      def path_target?
        @target.to_s.include?("/") || @target.to_s.start_with?("~", ".")
      end

      # An all-digits target is unambiguously a task id: Stages::SLUG_RE
      # requires a leading lowercase letter, so no slug can be all digits.
      #
      # This /\A\d+\z/ predicate is duplicated, deliberately, in
      # TaskResolver#numeric_target? and the two MUST stay in lockstep: Drop
      # uses it to route a target onto the resolver path *before* it can build
      # the resolver, so a shared instance method isn't reachable here. If the
      # rule ever changes (signs, base, width caps), change BOTH — otherwise a
      # target routes one way here and resolves the other way there.
      def numeric_target?
        @target.to_s.match?(/\A\d+\z/)
      end

      # Path/id targets flow through TaskResolver so path validation and
      # numeric-id lookup stay shared with run/approve/findings.
      def resolve_path_context
        task = Hive::TaskResolver.new(
          @target,
          project_filter: @project_filter,
          stage_filter: @stage_filter
        ).resolve
        project_name = project_name_for(task)
        # Re-assert the task's overlay and snapshot its active + terminal stage
        # dirs under ONE lock hold (TaskResolver already loaded this project via
        # Task#resolve_workflow). Capturing both here, rather than reading the
        # live `archive_stage_dirs`/`active_stage_dirs` again at guard time,
        # closes the window where a concurrent overlay swap could change which
        # dirs count as archived between the find and guard_archived!'s check —
        # which would hard-delete a completed task instead of refusing it.
        active_dirs, archive_dirs = Hive::Workflows::Project.synchronize do
          Hive::Workflows::Project.load!(task.project_root)
          [ active_stage_dirs, archive_stage_dirs ]
        end
        folders = collect_stage_folders(task.hive_state_path, task.slug, active_dirs)
        # Same outcome as resolve_slug_context, inverted mechanism: if the
        # path/id target landed on the archive stage (no active folders, but the
        # archive folder exists) surface the archive match so guard_archived!
        # refuses cleanly instead of silently dropping nothing. Here that's an
        # explicit empty-active fallback (collect against archive_dirs only when
        # `folders` came back empty); resolve_slug_context reaches the same end
        # by *not rejecting* the archive folders when no active ones remain
        # (the `@stage_filter.nil?` keep-archive branch in resolve_slug_context).
        if folders.empty?
          archived = collect_stage_folders(task.hive_state_path, task.slug, archive_dirs)
          folders = archived unless archived.empty?
        end
        TaskContext.new(
          slug: task.slug,
          project_name: project_name,
          project_root: task.project_root,
          hive_state_path: task.hive_state_path,
          folders: folders,
          from_stages: folders.map { |f| f[:stage] },
          archive_stage_dirs: archive_dirs
        )
      end

      def resolve_slug_context
        projects = Hive::Config.registered_projects
        projects = projects.select { |p| p["name"] == @project_filter } if @project_filter
        matches_by_project = projects.filter_map do |project|
          # Scan the union of every registered workflow's stage dirs (not just
          # the coding stages) so a generic task folder is findable by slug.
          # `Hive::Workflows.stages_for_project` (the shared per-project
          # resolution rule, also used by Hive::TaskResolver) loads each
          # project's overlay in turn, then returns the cross-workflow stage-dir
          # union or the single filtered dir; it tolerates a stage_filter absent
          # from THIS project so one project's mismatch doesn't abort the slug
          # scan across healthy projects. Note the active overlay is the LAST
          # project scanned here, so the matched project's overlay is reloaded
          # below before any terminal/archive-dir computation.
          stages = Hive::Workflows.stages_for_project(project, stage_filter: @stage_filter)
          folders = collect_stage_folders(project["hive_state_path"], @target, stages)
          next if folders.empty?

          [ project, folders ]
        end

        if matches_by_project.empty?
          raise_wrong_stage_if_slug_exists_elsewhere!
          # A `--from` that names no stage in ANY registered project is a usage
          # error, not a missing slug: surface "unknown stage '<x>'" (the
          # diagnostic the eager constructor used to emit) instead of the
          # generic "no task folder for slug" — stages_for_project tolerates a
          # per-project mismatch and otherwise swallows it.
          Hive::Workflows.assert_known_stage_filter!(@stage_filter, projects)
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
        # The slug scan above loaded each project's overlay in turn, leaving the
        # LAST-scanned project's workflows active. Reload the MATCHED project's
        # overlay and CAPTURE its terminal stage dirs under the SAME lock hold,
        # so a concurrent `load!(otherProject)` can't swap the overlay between
        # this reload and guard_archived!'s read — which would recompute the
        # archive guard against another project's terminal dirs and hard-delete
        # a completed custom-workflow task instead of refusing it. The captured
        # set travels in TaskContext and is the ONLY archive-dir source the rest
        # of the drop consults (no live recomputation downstream).
        archive_dirs = Hive::Workflows::Project.synchronize do
          Hive::Workflows::Project.load!(project["path"])
          archive_stage_dirs
        end
        if @stage_filter.nil?
          active_folders = folders.reject { |f| archive_dirs.include?(f[:stage]) }
          folders = active_folders unless active_folders.empty?
        end
        TaskContext.new(
          slug: @target,
          project_name: project["name"],
          project_root: project["path"],
          hive_state_path: project["hive_state_path"],
          folders: folders,
          from_stages: folders.map { |f| f[:stage] },
          archive_stage_dirs: archive_dirs
        )
      end

      def collect_stage_folders(hive_state_path, slug, stages)
        Array(stages).filter_map do |stage|
          folder = File.join(hive_state_path, "stages", stage, slug)
          next unless File.directory?(folder)

          begin
            { stage: stage, folder: File.realpath(folder) }
          rescue Errno::ENOENT
            # Concurrent unlink between directory? and realpath (another
            # drop, an operator `rm -rf`). Collapse into the idempotent
            # "treat as gone" path the rest of the file uses.
            nil
          end
        end
      end

      def raise_wrong_stage_if_slug_exists_elsewhere!
        return unless @stage_filter

        projects = Hive::Config.registered_projects
        projects = projects.select { |p| p["name"] == @project_filter } if @project_filter
        all_matches = projects.flat_map do |project|
          Hive::Workflows::Project.load!(project["path"])
          collect_stage_folders(project["hive_state_path"], @target, Hive::Workflows.all_stage_dirs).map do |folder|
            [ project, folder ]
          end
        end
        return if all_matches.empty? || all_matches.map { |project, _| project["name"] }.uniq.size > 1

        matched_project = all_matches.first[0]
        actual_stage = all_matches.first[1][:stage]
        # The scan loop above left the LAST project's overlay active. Reload the
        # MATCHED project's overlay so "expected" resolves against the workflow
        # the slug actually belongs to, not the last one scanned. A filter that
        # doesn't resolve in the matched project degrades to the raw ref rather
        # than raising mid-message. (No-op when the matched project was scanned
        # last: load! short-circuits on unchanged @active_root.)
        Hive::Workflows::Project.load!(matched_project["path"])
        expected_stage =
          begin
            Hive::Workflows.resolve_stage_ref_across_workflows(@stage_filter)
          rescue Hive::InvalidTaskPath
            @stage_filter
          end
        raise Hive::WrongStage.new(
          "task is at #{actual_stage} but --from expected #{expected_stage}",
          current_stage: actual_stage,
          target_stage: expected_stage
        )
      end

      def project_name_for(task)
        match = Hive::Config.registered_projects.find { |p| p["path"] == task.project_root }
        match ? match["name"] : task.project_name
      end

      # Shares Hive::TaskResolver's formatter so the two not-found hints stay
      # byte-identical. `@from` IS `@stage_filter` (set equal in the ctor).
      def project_hint
        Hive::TaskResolver.project_hint(project_filter: @project_filter, stage_filter: @from)
      end

      def guard_archived!(context)
        # Read the archive set CAPTURED under the overlay lock at resolve time,
        # not the live `archive_stage_dirs` (which reflects whatever overlay is
        # active now). This is the half of the fix that makes the capture matter:
        # a concurrent overlay swap between resolve and here can't reopen the
        # archived-task hard-delete bug.
        archive_dirs = context.archive_stage_dirs
        return unless context.folders.any? && context.folders.all? { |f| archive_dirs.include?(f[:stage]) }

        raise AlreadyArchived, "task #{context.slug} is at #{context.from_stages.uniq.join(', ')}; nothing to drop"
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
          skipped_reason: skipped_reasons.compact.first
        }
      end

      def process_candidates(folders)
        by_pid = {}
        folders.each do |entry|
          lock = lock_payload(File.join(entry[:folder], ".lock"))
          if integer_like?(lock["claude_pid"])
            register_candidate(by_pid, lock["claude_pid"].to_i,
                               process_start_time: lock["claude_pid_start_time"], group: true)
          end
          if integer_like?(lock["pid"])
            register_candidate(by_pid, lock["pid"].to_i,
                               process_start_time: lock["process_start_time"], group: false)
          end

          marker = marker_for(entry[:folder])
          marker_pid = marker.attrs["pid"]
          next unless marker.name == :agent_working && integer_like?(marker_pid)

          register_candidate(
            by_pid, marker_pid.to_i,
            process_start_time: lock["pid"].to_i == marker_pid.to_i ? lock["process_start_time"] : nil,
            group: false
          )
        end
        by_pid.values
      end

      # `group: true` always wins — a claude_pid==pid lock would
      # otherwise clobber the group-kill into a single-process kill
      # and orphan the agent's children.
      def register_candidate(by_pid, pid, process_start_time:, group:)
        existing = by_pid[pid]
        merged_start_time = (existing && existing[:process_start_time]) || process_start_time
        merged_group = (existing && existing[:group]) || group
        by_pid[pid] = {
          pid: pid,
          process_start_time: merged_start_time,
          group: merged_group
        }
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
        return false unless value.is_a?(Integer) || value.to_s.match?(/\A\s*\d+\s*\z/)

        # Reject pid <= 1 here so a corrupted `.lock` or marker cannot
        # leak PID 0 (current process group) or PID 1 (init) through
        # to ProcessKill. ProcessKill enforces the same rule again as
        # defense in depth.
        value.to_i > 1
      end

      def close_draft_prs(folders)
        urls = folders.filter_map do |entry|
          frontmatter = Hive::Gh.pr_frontmatter(File.join(entry[:folder], "pr.md"))
          frontmatter["pr_url"].to_s.strip.empty? ? nil : frontmatter["pr_url"].to_s.strip
        end.uniq
        # No PR recorded = PR cleanup is clean. `false` strictly means "a PR
        # existed and could not be closed" — that distinction is what lets
        # the web tier qualify its Dropped notice without false alarms on
        # the common case (dropping an idea that never reached open-pr).
        return true if urls.empty?

        comment = "task dropped (hive drop #{@target})"
        closed_any = false
        urls.each do |url|
          out, err, status = Hive::Gh.capture3("gh", "pr", "close", url, "--comment", comment)
          if status.success?
            closed_any = true
          else
            warn "[hive] drop: gh pr close #{url} failed (continuing): #{err.to_s.strip.empty? ? out : err}"
          end
        rescue Hive::GhError => e
          warn "[hive] drop: gh pr close skipped: #{e.message}"
        end
        closed_any
      end

      def remove_worktrees(context, folders)
        worktree_root = canonical_worktree_root(context)
        wt = Hive::Worktree.new(context.project_root, context.slug, worktree_root: worktree_root)
        paths = worktree_paths(context, folders, worktree_root: worktree_root, wt: wt)
        return false if paths.empty?

        # Hoist the porcelain list ONCE per drop so a slug with >1
        # candidate path doesn't fork `git worktree list` N times.
        registered_paths = wt.list_worktree_paths
        removed = false
        paths.each do |path|
          removed = remove_one_worktree(wt, path, registered_paths: registered_paths) || removed
        end
        Hive::GitOps.new(context.project_root).prune_worktrees!
        removed
      end

      def remove_one_worktree(wt, path, registered_paths:)
        return false unless File.directory?(path) || registered_paths.include?(path)

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

      # Treats an out-of-root pointer escape as "no worktree to remove"
      # (best-effort cleanup) so a tampered pointer cannot abort drop —
      # see `Hive::Worktree.validate_pointer_path` for the rule.
      def worktree_paths(context, folders, worktree_root:, wt:)
        paths = folders.filter_map do |entry|
          pointer = Hive::Worktree.read_pointer(entry[:folder])
          next unless pointer && pointer["path"]

          Hive::Worktree.validate_pointer_path(pointer["path"], worktree_root)
        rescue Hive::WorktreeError => e
          # Security-relevant breadcrumb: someone (or something) wrote
          # a pointer outside the configured worktree root. Drop
          # converges silently here, but the operator needs a signal
          # in stderr that the rejected path was seen.
          warn "[hive] drop: rejecting out-of-root worktree pointer in #{entry[:folder]}: #{e.message[0, 200]}"
          nil
        end
        paths << wt.path
        paths.compact.map { |path| File.expand_path(path) }.uniq
      end

      def canonical_worktree_root(context)
        Hive::Worktree.canonical_root(context.project_root)
      end

      def delete_branch(context)
        Hive::GitOps.new(context.project_root).delete_branch!(context.slug)
      end

      def remove_task_folders(context)
        # Remove exactly the stages the task was found in (`from_stages`), not
        # a fixed coding-only stage sweep — otherwise a generic task whose stage
        # dir isn't in the coding set would be reported dropped while its folder
        # survived on disk. `from_stages` is the authoritative found-set (archive
        # copies are already excluded by the resolver), so this is a no-op for
        # the same coding rows as before.
        context.from_stages.each do |stage|
          FileUtils.rm_rf(File.join(context.hive_state_path, "stages", stage, context.slug))
        end
      end

      # Active stage dirs across EVERY registered workflow (coding + generic),
      # minus the archive stages — the set `hive drop` may hard-delete from.
      def active_stage_dirs
        Hive::Workflows.all_stage_dirs.reject { |stage| archive_stage_dirs.include?(stage) }
      end

      # Terminal ("archived") stage dir of EVERY registered workflow, not just
      # coding's 9-done. A completed generic-workflow task sits at its own
      # terminal dir, so `guard_archived!` must recognize the whole union or it
      # would hard-delete a finished generic task that `AlreadyArchived` should
      # refuse. Shares `Hive::Workflows.all_terminal_stage_dirs` with init's
      # fieldless-task scan, and stays in lockstep with `active_stage_dirs` (the
      # workflow union minus this set).
      def archive_stage_dirs
        Hive::Workflows.all_terminal_stage_dirs
      end

      def record_drop_commit!(context)
        rel_paths = context.from_stages.map { |stage| File.join("stages", stage, context.slug) }
        rel_paths << File.join("logs", context.slug)
        body = "Dropped task #{context.slug} from stages: #{context.from_stages.join(', ')}"
        body = "#{body}\n\n#{JSON.generate(drop_audit_record)}" if @audit
        # `allow_empty: true` collapses the result to the single
        # "committed" symbol — drop always writes a commit so the
        # audit trail is complete, even when the working tree was
        # already clean from a prior interrupted run.
        result = Hive::GitOps.new(context.project_root).hive_commit(
          stage_name: "dropped",
          slug: context.slug,
          action: "dropped",
          body: body,
          pathspecs: rel_paths,
          allow_empty: true
        )
        result.to_s
      end

      def drop_audit_record
        {
          "event_type" => "operator_action",
          "agent" => "web:#{@audit['actor']}",
          "actor" => @audit["actor"],
          "request_id" => @audit["request_id"],
          "from" => @audit["from"],
          "to" => @audit["to"],
          "direction" => @audit["direction"],
          "confirmation_reason" => @audit["reason"]
        }.compact
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
