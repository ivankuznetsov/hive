require "fileutils"
require "json"
require "open3"
require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/lock"
require "hive/git_ops"
require "hive/stages"

module Hive
  module Commands
    # Move a task folder between stages and record a hive/state commit. The
    # agent-callable replacement for shell `mv <task> <next-stage>/`.
    #
    # Resolution paths for `target`:
    #   - path-shaped (contains '/' or starts with '~'/'.') → used directly
    #   - bare slug → searched across registered projects (or the one given
    #     by --project) for an unambiguous match. Multi-stage hits inside
    #     one project are now treated as ambiguous (caller passes a folder
    #     path or --to to disambiguate); silently picking the lowest stage
    #     was wrong for the partial-failure-recovery case.
    #
    # Forward auto-advance requires a terminal marker (`:complete` /
    # `:execute_complete`). Backward `--to <stage>` is a recovery action and
    # bypasses the marker check; `--force` bypasses it on forward moves too.
    #
    # `--from STAGE` is the agent-side idempotency lever: pass the stage the
    # caller *believes* the task is at; if the task has already been advanced
    # by a prior call, the assertion fails with WRONG_STAGE (4) so retry
    # loops can branch deterministically.
    class Approve
      VALID_TERMINAL_MARKERS = %i[complete execute_complete].freeze

      def initialize(target, to: nil, from: nil, project: nil, force: false, json: false)
        @target = target
        @to = to
        @from = from
        @project_filter = project
        @force = force
        @json = json
      end

      def call
        do_call
      rescue Hive::Error => e
        emit_error_envelope(e) if @json
        raise
      end

      private

      def do_call
        folder = resolve_target
        task = Hive::Task.new(folder)
        validate_project_path_match!(task)
        validate_from!(task) if @from
        next_stage_dir = resolve_destination(task)

        return emit_noop(task, next_stage_dir) if same_stage?(task, next_stage_dir)

        marker = Hive::Markers.current(task.state_file)
        validate_move!(task, next_stage_dir, marker)
        direction = direction_of(task, next_stage_dir)

        new_folder, commit_action = perform_move_and_commit(task, next_stage_dir)
        emit_success(task, next_stage_dir, new_folder, marker, commit_action, direction)
      end

      # ── Resolution ──────────────────────────────────────────────────────

      def resolve_target
        # File.realpath resolves any symlink in the path. A slug-named
        # symlink at `.hive-state/stages/<N>/<slug>` pointing to
        # `/tmp/leaked` realpaths to `/tmp/leaked`, which Task.new's
        # PATH_RE then refuses — the real path doesn't match the
        # .hive-state/stages/ shape. Applies to both the explicit-folder
        # path and the slug-search return so neither code path can be
        # used to mv a slug-shaped symlink onto external data.
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
        @project_filter ? " in project '#{@project_filter}'" : ""
      end

      def ambiguity_message(matches)
        projects = matches.map { |m| m[:project] }.uniq
        if projects.size > 1
          "slug '#{@target}' is ambiguous (in #{projects.join(', ')}); pass --project <name>"
        else
          stages = matches.map { |m| m[:stage] }
          "slug '#{@target}' is ambiguous (multiple stages in '#{projects.first}': #{stages.join(', ')}); " \
            "pass an absolute folder path"
        end
      end

      # Returns every stage hit across registered projects (filtered by
      # --project if given) as { project:, stage:, folder: } hashes. Same-
      # project multi-stage hits are kept — disambiguation is the caller's
      # job, not silent picking.
      def find_slug_across_projects(slug)
        projects = Hive::Config.registered_projects
        projects = projects.select { |p| p["name"] == @project_filter } if @project_filter
        projects.flat_map do |project|
          Hive::Stages::DIRS.filter_map do |stage|
            folder = File.join(project["hive_state_path"], "stages", stage, slug)
            next nil unless File.directory?(folder)

            { project: project["name"], stage: stage, folder: folder }
          end
        end
      end

      def resolve_destination(task)
        return resolve_explicit_to(@to) if @to

        Hive::Stages.next_dir(task.stage_index) ||
          raise(Hive::FinalStageReached.new(
                  "task is already at the final stage (#{task.stage_index}-#{task.stage_name})",
                  stage: "#{task.stage_index}-#{task.stage_name}"
                ))
      end

      def resolve_explicit_to(to)
        Hive::Stages.resolve(to) ||
          raise(Hive::InvalidTaskPath,
                "unknown stage '#{to}'; valid: #{Hive::Stages::DIRS.join(', ')} " \
                "or short names #{Hive::Stages::NAMES.join(', ')}")
      end

      # ── Validation ──────────────────────────────────────────────────────

      def validate_project_path_match!(task)
        return unless @project_filter
        return unless path_target?

        matching = Hive::Config.registered_projects.find { |p| p["path"] == task.project_root }
        actual_name = matching ? matching["name"] : File.basename(task.project_root)
        return if actual_name == @project_filter

        raise Hive::InvalidTaskPath,
              "TARGET path is in project '#{actual_name}' but --project says '#{@project_filter}'"
      end

      def validate_from!(task)
        expected = Hive::Stages.resolve(@from) ||
                   raise(Hive::InvalidTaskPath,
                         "unknown --from stage '#{@from}'; valid: #{Hive::Stages::DIRS.join(', ')}")
        actual = "#{task.stage_index}-#{task.stage_name}"
        return if expected == actual

        raise Hive::WrongStage,
              "task is at #{actual} but --from expected #{expected} " \
              "(idempotency check: a prior call may have already advanced this task)"
      end

      def validate_move!(task, dest_stage, marker)
        dest_idx, = Hive::Stages.parse(dest_stage)
        return if dest_idx <= task.stage_index || @force
        return if VALID_TERMINAL_MARKERS.include?(marker.name)

        raise Hive::WrongStage,
              "task #{task.slug} marker is :#{marker.name}; forward approve requires a terminal marker " \
              "(:complete or :execute_complete). Use --force to override or --to to move backward."
      end

      def same_stage?(task, dest_stage)
        dest_idx, dest_name = Hive::Stages.parse(dest_stage)
        dest_idx == task.stage_index && dest_name == task.stage_name
      end

      def direction_of(task, dest_stage)
        dest_idx, = Hive::Stages.parse(dest_stage)
        return "forward" if dest_idx > task.stage_index
        return "backward" if dest_idx < task.stage_index

        "same"
      end

      # ── Mutation ────────────────────────────────────────────────────────

      # Locking strategy:
      #   - commit_lock OUTERMOST: serialises hive/state writes and surfaces
      #     contention (e.g. a 30s commit-lock-held timeout) BEFORE we touch
      #     the filesystem. A failed acquire never leaves a half-applied move.
      #   - task_lock INNER: blocks a concurrent `hive run` on the same task
      #     during the mv. The .lock file moves with the folder; the standard
      #     release no-ops on the gone source path. We delete the orphan at
      #     the new path before committing so the per-process lock metadata
      #     isn't tracked in hive/state.
      def perform_move_and_commit(task, dest_stage)
        new_folder = nil
        commit_action = nil
        Hive::Lock.with_commit_lock(task.hive_state_path) do
          Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: "approve") do
            new_folder = move_task!(task, dest_stage)
          end
          cleanup_orphan_task_lock(new_folder)
          commit_action = "approve #{task.stage_index}-#{task.stage_name} -> #{dest_stage}"
          record_commit_or_rollback!(task, dest_stage, new_folder, commit_action)
        end
        [ new_folder, commit_action ]
      end

      def move_task!(task, dest_stage)
        new_parent = File.join(task.hive_state_path, "stages", dest_stage)
        FileUtils.mkdir_p(new_parent)
        new_folder = File.join(new_parent, task.slug)

        # Pre-check is the early-exit fast path; the rescue below is the
        # real safety net. A concurrent process can mkdir the destination
        # between this check and File.rename — an empty dir there would
        # cause rename to silently REPLACE it (POSIX rename(2) semantics),
        # and a non-empty dir surfaces as ENOTEMPTY which we catch.
        raise_destination_collision(new_folder) if File.exist?(new_folder)

        begin
          File.rename(task.folder, new_folder)
        rescue Errno::ENOTEMPTY, Errno::EEXIST, Errno::EISDIR
          raise_destination_collision(new_folder)
        rescue Errno::EXDEV
          # Cross-device move (rare; .hive-state lives under the project
          # root by construction). Fall back to copy + remove.
          FileUtils.cp_r(task.folder, new_folder)
          FileUtils.rm_rf(task.folder)
        end
        new_folder
      end

      def raise_destination_collision(path)
        raise Hive::DestinationCollision.new(
          "destination already exists: #{path} (slug collision; archive or rename the existing folder)",
          path: path
        )
      end

      def cleanup_orphan_task_lock(new_folder)
        lock_path = File.join(new_folder, ".lock")
        File.delete(lock_path) if File.exist?(lock_path)
      end

      # Slug-scoped commit. Adding the parent stage dir would sweep unrelated
      # sibling-task changes into our commit message; scoping to the slug
      # path on both ends keeps the audit trail accurate. We add the
      # destination unconditionally, and the source only if it has tracked
      # files — `git add -A <pathspec>` errors with "did not match any
      # files" when the pathspec is gone from the worktree AND has no
      # tracked entries (a slug freshly moved between previously-untracked
      # stages, e.g. inbox→brainstorm in the common forward flow).
      def record_hive_commit(task, dest_stage, action)
        message = "hive: #{task.stage_index}-#{task.stage_name}/#{task.slug} #{action}"
        ops = Hive::GitOps.new(task.project_root)
        source_slug_rel = File.join("stages", "#{task.stage_index}-#{task.stage_name}", task.slug)
        dest_slug_rel = File.join("stages", dest_stage, task.slug)

        ops.run_git!("-C", task.hive_state_path, "add", "-A", dest_slug_rel)
        if source_has_tracked_files?(task.hive_state_path, source_slug_rel)
          ops.run_git!("-C", task.hive_state_path, "add", "-A", source_slug_rel)
        end

        _, _, status = Open3.capture3("git", "-C", task.hive_state_path, "diff", "--cached", "--quiet")
        ops.run_git!("-C", task.hive_state_path, "commit", "-m", message) unless status.success?
      end

      def source_has_tracked_files?(hive_state_path, source_rel)
        out, _, _ = Open3.capture3("git", "-C", hive_state_path, "ls-files", "--", source_rel)
        !out.strip.empty?
      end

      # If the commit fails (pre-commit hook abort, disk full, hive/state
      # branch corruption), mv the folder back to the source so the
      # filesystem and git history don't diverge. If rollback isn't possible
      # (source path was somehow re-created in the meantime), surface a clear
      # manual-recovery message instead of compounding the problem.
      def record_commit_or_rollback!(task, dest_stage, new_folder, action)
        record_hive_commit(task, dest_stage, action)
      rescue StandardError => e
        if new_folder && File.directory?(new_folder) && !File.exist?(task.folder)
          FileUtils.mv(new_folder, task.folder)
          raise Hive::Error,
                "approve aborted; mv rolled back to #{task.folder}. underlying: #{e.class}: #{e.message}"
        end

        raise Hive::Error,
              "approve aborted but rollback NOT possible (source path now exists); " \
              "manual recovery: task is at #{new_folder}, original was #{task.folder}. " \
              "underlying: #{e.class}: #{e.message}"
      end

      # ── Reporting ───────────────────────────────────────────────────────

      def emit_noop(task, dest_stage)
        if @json
          puts JSON.generate(success_payload(task, dest_stage, task.folder, nil, nil, "same", noop: true))
        else
          puts "hive: noop — #{task.slug} already at #{dest_stage}"
        end
      end

      def emit_success(task, dest_stage, new_folder, marker, commit_action, direction)
        if @json
          puts JSON.generate(success_payload(task, dest_stage, new_folder, marker, commit_action, direction))
        else
          puts "hive: approved #{task.slug}"
          puts "  from: #{task.folder}"
          puts "  to:   #{new_folder}"
          # Hint goes to stderr so a `| jq` consumer doesn't get prose mixed
          # with data when the user forgot --json.
          warn "next: hive run #{new_folder}"
        end
      end

      def success_payload(task, dest_stage, new_folder, marker, commit_action, direction, noop: false)
        dest_idx, dest_name = Hive::Stages.parse(dest_stage)
        payload = {
          "schema" => "hive-approve",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-approve"),
          "ok" => true,
          "noop" => noop,
          "slug" => task.slug,
          "from_stage" => task.stage_name,
          "from_stage_index" => task.stage_index,
          "from_stage_dir" => "#{task.stage_index}-#{task.stage_name}",
          "to_stage" => dest_name,
          "to_stage_index" => dest_idx,
          "to_stage_dir" => dest_stage,
          "direction" => direction,
          "forced" => @force,
          "from_folder" => task.folder,
          "to_folder" => new_folder,
          "from_marker" => marker ? marker.name.to_s : nil,
          "commit_action" => commit_action,
          "next_action" => json_next_action(new_folder, dest_idx)
        }
        payload
      end

      def json_next_action(new_folder, dest_idx)
        kind = Hive::Schemas::NextActionKind
        if Hive::Stages.next_dir(dest_idx)
          { "kind" => kind::RUN, "folder" => new_folder, "command" => "hive run #{new_folder}" }
        else
          { "kind" => kind::NO_OP, "reason" => "final_stage" }
        end
      end

      def emit_error_envelope(error)
        payload = {
          "schema" => "hive-approve",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-approve"),
          "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error_kind_for(error),
          "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::GENERIC,
          "message" => error.message
        }
        payload["candidates"] = error.candidates if error.is_a?(Hive::AmbiguousSlug)
        payload["path"] = error.path if error.is_a?(Hive::DestinationCollision)
        payload["stage"] = error.stage if error.is_a?(Hive::FinalStageReached)
        puts JSON.generate(payload)
      end

      def error_kind_for(error)
        case error
        when Hive::AmbiguousSlug then "ambiguous_slug"
        when Hive::DestinationCollision then "destination_collision"
        when Hive::FinalStageReached then "final_stage"
        when Hive::WrongStage then "wrong_stage"
        when Hive::InvalidTaskPath then "invalid_task_path"
        else "error"
        end
      end
    end
  end
end
