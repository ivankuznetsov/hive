require "fileutils"
require "json"
require "open3"
require "hive/config"
require "hive/task"
require "hive/task_resolver"
require "hive/task_action"
require "hive/markers"
require "hive/lock"
require "hive/git_ops"
require "hive/stages"
require "hive/workflows"
require "hive/commit_or_rollback"

module Hive
  module Commands
    # Move a task folder between stages and record a hive/state commit. The
    # agent-callable equivalent of shell `mv <task> <next-stage>/`.
    #
    # Resolution paths for `target`:
    #   - path-shaped (contains '/' or starts with '~'/'.') → used directly
    #   - bare slug → searched across registered projects (or the one given
    #     by --project) for an unambiguous match. Multi-stage hits inside
    #     one project are treated as ambiguous; the caller must pass an
    #     absolute folder path to pick a specific stage (--to selects the
    #     destination, not the source).
    #
    # Forward auto-advance requires a terminal marker (`:complete` /
    # `:execute_complete` / `:review_complete`). Backward `--to <stage>` is a
    # recovery action and bypasses the marker check; `--force` bypasses it on
    # forward moves too.
    #
    # `--from STAGE` is the agent-side idempotency lever: pass the stage the
    # caller *believes* the task is at; if the task has already been advanced
    # by a prior call, the assertion fails with WRONG_STAGE (4) so retry
    # loops can branch deterministically.
    class Approve
      VALID_TERMINAL_MARKERS = %i[complete execute_complete review_complete].freeze

      def initialize(target, to: nil, from: nil, project: nil, force: false, json: false, quiet: false)
        @target = target
        @to = to
        @from = from
        @project_filter = project
        @force = force
        @json = json
        # Suppress all stdout/stderr emission. Used by composing callers
        # (e.g. StageAction) that emit their own unified envelope.
        # State changes and typed exceptions still propagate normally.
        @quiet = quiet
      end

      def call
        do_call
      rescue Hive::Error => e
        emit_error_envelope(e) if @json && !@quiet
        raise
      rescue StandardError => e
        # Anything that isn't a typed Hive::Error is an internal bug or an
        # I/O fault we didn't anticipate (Errno::ENOSPC from mkdir_p, an
        # Open3 failure, a SystemCallError from the cross-device fallback).
        # Translate to InternalError so --json callers still get a parseable
        # envelope on stdout instead of a Ruby trace on stderr, and the
        # exit code is the documented SOFTWARE (70) rather than nothing.
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_error_envelope(wrapped) if @json && !@quiet
        raise wrapped
      end

      private

      # ── Pipeline ────────────────────────────────────────────────────────

      def do_call
        task = resolve_task
        validate_from!(task) if @from
        next_stage_dir = resolve_destination(task)

        return emit_noop(task, next_stage_dir) if same_stage?(task, next_stage_dir)

        marker = Hive::Markers.current(task.state_file)
        validate_move!(task, next_stage_dir, marker)
        direction = direction_of(task, next_stage_dir)

        new_folder, commit_action = perform_move_and_commit(task, next_stage_dir)
        emit_success(task, next_stage_dir, new_folder, marker, commit_action, direction)
      end

      # ── Destination resolution ──────────────────────────────────────────

      def resolve_task
        return Hive::TaskResolver.new(@target, project_filter: @project_filter).resolve unless @from

        Hive::TaskResolver.new(
          @target,
          project_filter: @project_filter,
          stage_filter: @from
        ).resolve
      rescue Hive::InvalidTaskPath
        # Preserve --from's idempotency contract: if a retry runs after the
        # task advanced, report WRONG_STAGE from validate_from! instead of
        # "not found in source stage".
        Hive::TaskResolver.new(@target, project_filter: @project_filter).resolve
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

        valid = VALID_TERMINAL_MARKERS.map { |m| ":#{m}" }.join(", ")
        raise Hive::WrongStage,
              "task #{task.slug} marker is :#{marker.name}; forward approve requires one of #{valid}. " \
              "Use --force to override or --to to move backward."
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
        # real safety net. POSIX rename(2) on a non-empty destination
        # directory raises ENOTEMPTY; on an empty destination directory
        # implementations vary (Linux glibc replaces; some libcs surface
        # as EEXIST/EISDIR). The rescue covers all three so the outcome
        # is uniform regardless of platform.
        raise_destination_collision(new_folder) if File.exist?(new_folder)

        begin
          File.rename(task.folder, new_folder)
        rescue Errno::ENOTEMPTY, Errno::EEXIST, Errno::EISDIR
          raise_destination_collision(new_folder)
        rescue Errno::EXDEV
          cross_device_move!(task.folder, new_folder)
        end
        new_folder
      end

      # Cross-device fallback: copy then remove. If the copy fails partway
      # through (ENOSPC mid-tree, EACCES on a child), tear down the partial
      # destination so the next retry doesn't hit a phantom "destination
      # exists" collision. The source is left intact on copy failure.
      def cross_device_move!(src, dst)
        FileUtils.cp_r(src, dst)
        FileUtils.rm_rf(src)
      rescue StandardError => e
        FileUtils.rm_rf(dst) if File.exist?(dst)
        raise Hive::Error,
              "cross-device move failed; partial destination cleaned up. " \
              "underlying: #{e.class}: #{e.message}"
      end

      def raise_destination_collision(path)
        raise Hive::DestinationCollision.new(
          "destination already exists: #{path} (slug collision; archive or rename the existing folder)",
          path: path
        )
      end

      # Only swallow ENOENT (lock already gone — concurrent process raced
      # us to delete it, or the lock module's release path beat us to it).
      # Other errors (EACCES on a read-only mount, IOError) need to surface
      # so the caller sees a typed exception and the rollback path runs.
      def cleanup_orphan_task_lock(new_folder)
        lock_path = File.join(new_folder, ".lock")
        File.delete(lock_path) if File.exist?(lock_path)
      rescue Errno::ENOENT
        # Already gone — nothing to do.
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

      # ls-files exits non-zero on a corrupt index or a missing repo. An
      # empty stdout from a successful run means "no tracked files at this
      # path"; the same empty stdout from a failed run would silently skip
      # staging the source-side deletion, leaving a tree-vs-index drift.
      # Distinguish the two and raise typed on git failure.
      def source_has_tracked_files?(hive_state_path, source_rel)
        out, err, status = Open3.capture3("git", "-C", hive_state_path, "ls-files", "--", source_rel)
        unless status.success?
          raise Hive::GitError,
                "git ls-files failed in #{hive_state_path}: #{err.strip.empty? ? out : err}"
        end

        !out.strip.empty?
      end

      # Two failure paths to handle distinctly:
      #   1. The git commit itself fails — caused by run_git! raising
      #      typed Hive::GitError (or similar). Rollback the move and
      #      surface the typed error so callers see the SOFTWARE (70)
      #      exit code, not a generic 1.
      #   2. The rollback mv itself fails (cross-device, EACCES, source
      #      re-created mid-flight). Both errors must surface — the
      #      original commit failure is the cause; the rollback failure
      #      is what actually blocks recovery.
      def record_commit_or_rollback!(task, dest_stage, new_folder, action)
        record_hive_commit(task, dest_stage, action)
      rescue Hive::Error, SystemCallError => e
        attempt_rollback!(task, new_folder, e)
      end

      def attempt_rollback!(task, new_folder, original_error)
        # The pre-condition check stays in this caller — the helper only
        # owns the rescue + re-raise contract. If the source path now
        # exists, an undo would clobber it; surface a manual-recovery
        # error instead of attempting and failing.
        unless new_folder && File.directory?(new_folder) && !File.exist?(task.folder)
          raise Hive::Error,
                "approve aborted but rollback NOT possible (source path now exists); " \
                "manual recovery: task is at #{new_folder}, original was #{task.folder}. " \
                "underlying: #{original_error.class}: #{original_error.message}"
        end

        Hive::CommitOrRollback.attempt!(
          original_error,
          on_undo: -> { FileUtils.mv(new_folder, task.folder) },
          rolled_back_message: lambda do |e|
            "approve aborted; mv rolled back to #{task.folder}. " \
              "underlying: #{e.class}: #{e.message}"
          end,
          rollback_failed_message: lambda do |orig, rb|
            "approve aborted AND rollback failed. " \
              "task is at #{new_folder}, original was #{task.folder}. " \
              "commit error: #{orig.class}: #{orig.message}. " \
              "rollback error: #{rb.class}: #{rb.message}"
          end
        )
      end

      # ── Reporting ───────────────────────────────────────────────────────

      def emit_noop(task, dest_stage)
        return if @quiet

        if @json
          puts JSON.generate(success_payload(task, dest_stage, task.folder, nil, nil, "same", noop: true))
        else
          puts "hive: noop — #{task.slug} already at #{dest_stage}"
        end
      end

      def emit_success(task, dest_stage, new_folder, marker, commit_action, direction)
        return if @quiet

        dest_idx, = Hive::Stages.parse(dest_stage)
        if @json
          puts JSON.generate(success_payload(task, dest_stage, new_folder, marker, commit_action, direction))
        else
          puts "hive: approved #{task.slug}"
          puts "  from: #{task.folder}"
          puts "  to:   #{new_folder}"
          # Hint goes to stderr so a `| jq` consumer doesn't get prose mixed
          # with data when the user forgot --json.
          warn "next: #{workflow_command_for(task.slug, dest_idx)}"
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
        # No verb advances out of the final stage; signal completion to
        # the agent so a retry-loop terminates instead of running
        # `hive archive` (which would no-op anyway after this round).
        return { "kind" => kind::NO_OP, "reason" => "final_stage" } unless Hive::Stages.next_dir(dest_idx)

        task = Hive::Task.new(new_folder)
        marker = Hive::Markers.current(task.state_file)
        action = Hive::TaskAction.for(task, marker)
        { "kind" => kind::RUN, "folder" => new_folder, "command" => action.command || "hive run #{new_folder}" }
      rescue Hive::InvalidTaskPath
        { "kind" => kind::RUN, "folder" => new_folder, "command" => "hive run #{new_folder}" }
      end

      def workflow_command_for(slug, stage_index)
        # After advancing INTO `stage_index`, the next user-facing
        # command is "run the stage's agent" — i.e. the verb whose
        # target is this stage. `hive plan <slug> --from 3-plan` after
        # arriving at 3-plan hits StageAction's at-target branch and
        # runs the plan agent (rather than emitting a verb that would
        # try to advance OUT and refuse on a non-terminal marker).
        stage_dir = Hive::Stages::DIRS[stage_index - 1]
        return "hive run #{slug}" unless stage_dir

        verb = Hive::Workflows.verb_arriving_at(stage_dir)
        verb ? "hive #{verb} #{slug} --from #{stage_dir}" : "hive run #{slug}"
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
        when Hive::RollbackFailed then "rollback_failed"
        when Hive::InvalidTaskPath then "invalid_task_path"
        else "error"
        end
      end
    end
  end
end
