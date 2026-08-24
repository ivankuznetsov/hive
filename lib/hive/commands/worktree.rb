require "json"
require "open3"
require "hive"
require "hive/config"
require "hive/events"
require "hive/lock"
require "hive/markers"
require "hive/stages/auto_commit"
require "hive/stages/clean_exit"
require "hive/stages/execute"
require "hive/task_resolver"
require "hive/worktree"

module Hive
  module Commands
    # Agent-callable inspection and bounded recovery for a task-owned coding
    # worktree. Mutations require the task's durable recovery marker and run
    # under its task lock. They repair files only; marker clearing and rerun
    # admission remain owned by the generation-guarded workflow.retry action.
    class Worktree
      include Hive::Schemas::EnvelopeEmitter

      SUBCOMMANDS = %w[status commit-residue discard-residue repair].freeze
      REPAIR_STRATEGIES = %w[commit discard].freeze

      def initialize(subcommand, target, project: nil, stage: nil, json: false,
                     paths: nil, message: nil, strategy: nil, complete_execute: false,
                     pointer_resolver: nil)
        @subcommand = subcommand.to_s
        @target = target
        @project_filter = project
        @stage_filter = stage
        @json = json
        @paths = paths
        @message = message
        @strategy = strategy
        @complete_execute = complete_execute == true
        @pointer_resolver = pointer_resolver
      end

      def call
        call_with_envelope { do_call }
      end

      def envelope_schema = "hive-worktree"

      def envelope_error_kind(error)
        case error
        when Hive::AmbiguousSlug then "ambiguous_slug"
        when Hive::InvalidTaskPath then "invalid_task_path"
        when Hive::ConcurrentRunError then "task_locked"
        when Hive::WorktreeError then "worktree_error"
        when Hive::UsageError then "invalid_arguments"
        else "error"
        end
      end

      def envelope_serialization_failure_policy = :raise

      private

      def do_call
        validate_arguments!
        task = Hive::TaskResolver.new(
          @target,
          project_filter: @project_filter,
          stage_filter: @stage_filter
        ).resolve
        cfg = Hive::Config.load(task.project_root)
        worktree_path = owned_worktree_path(task, cfg)

        payload = if @subcommand == "status"
          status_payload(task, worktree_path, action: "status")
        else
          Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: "worktree.#{@subcommand}") do
            marker = recovery_marker!(task)
            mutate(task, cfg, worktree_path, marker)
          end
        end
        @json ? puts(JSON.generate(payload)) : render_text(payload)
      end

      def validate_arguments!
        unless SUBCOMMANDS.include?(@subcommand)
          raise Hive::UsageError,
                "unknown worktree subcommand #{@subcommand.inspect} (expected: #{SUBCOMMANDS.join(', ')})"
        end
        raise Hive::UsageError, "worktree subcommand requires TARGET" if @target.to_s.strip.empty?
        if @subcommand == "status" && (paths_supplied? || [ @message, @strategy ].any? { |value| !value.to_s.empty? })
          raise Hive::UsageError, "hive worktree status does not accept --paths, --message, or --strategy"
        end
        if @subcommand == "repair" && !REPAIR_STRATEGIES.include?(@strategy.to_s)
          raise Hive::UsageError,
                "hive worktree repair requires --strategy commit|discard"
        end
        if @subcommand != "repair" && !@strategy.to_s.empty?
          raise Hive::UsageError, "--strategy applies only to hive worktree repair"
        end
        if effective_action == "commit-residue" && paths_supplied?
          raise Hive::UsageError, "--paths applies only to discard-residue recovery"
        end
        if effective_action == "discard-residue" && !@message.to_s.empty?
          raise Hive::UsageError, "--message applies only to commit-residue recovery"
        end
        if @complete_execute && effective_action != "commit-residue"
          raise Hive::UsageError, "--complete-execute applies only to commit-residue recovery"
        end
        validate_subject! unless @message.to_s.empty?
      end

      def effective_action
        return "commit-residue" if @subcommand == "repair" && @strategy == "commit"
        return "discard-residue" if @subcommand == "repair" && @strategy == "discard"

        @subcommand
      end

      def paths_supplied?
        !Array(@paths).empty?
      end

      def validate_subject!
        subject = @message.to_s
        if subject.match?(/[[:cntrl:]]/) || subject.strip.empty? || subject.bytesize > 120
          raise Hive::UsageError, "--message must be one non-empty line of at most 120 bytes"
        end
      end

      def owned_worktree_path(task, cfg)
        return @pointer_resolver.call(task, cfg) if @pointer_resolver

        expected_root = Hive::Worktree.canonical_root(task.project_root, config: cfg)
        pointer = Hive::Worktree.read_owned_pointer(
          task.folder,
          project_root: task.project_root,
          slug: task.slug,
          expected_root: expected_root
        )
        pointer.fetch("path")
      end

      def recovery_marker!(task)
        marker = Hive::Markers.current(task.state_file)
        reason = marker.attrs["reason"].to_s
        eligible = (marker.name == :error && %w[ensure_clean_on_exit_failed dirty_worktree].include?(reason)) ||
                   (marker.name == :execute_waiting && reason == "dirty_worktree")
        return marker if eligible

        raise Hive::WorktreeError,
              "task #{task.slug} is not in a worktree-residue recovery state " \
              "(observed #{marker.name} reason=#{reason.empty? ? '(none)' : reason})"
      end

      def mutate(task, cfg, worktree_path, marker)
        case effective_action
        when "commit-residue"
          commit_residue(task, cfg, worktree_path)
        when "discard-residue"
          discard_residue(task, worktree_path, marker)
        end
      end

      def commit_residue(task, cfg, worktree_path)
        reason = @complete_execute ? :execute_residue_recovery : :operator_recovery
        result = Hive::Stages::CleanExit.run!(
          worktree_path: worktree_path,
          stage: "#{task.stage_index}-#{task.stage_name}",
          task: task,
          cfg: cfg,
          reason: reason,
          subject: (@message unless @message.to_s.empty?)
        )
        unless %i[clean auto_committed].include?(result[:status])
          raise Hive::WorktreeError, display_message(result[:message])
        end

        execute_completed = false
        if @complete_execute
          marker = Hive::Markers.current(task.state_file)
          unless marker.name == :error && marker.attrs["reason"].to_s == "dirty_worktree"
            raise Hive::WorktreeError,
                  "--complete-execute requires ERROR reason=dirty_worktree"
          end
          Hive::Stages::Execute.recover_committed_residue!(task, cfg, worktree_path)
          execute_completed = true
        end

        status_payload(task, worktree_path, action: "commit-residue").merge(
          "commit" => result[:head],
          "committed_paths" => display_paths(result[:paths]),
          "commit_subject" => result[:commit_subject],
          "execute_completed" => execute_completed
        )
      end

      def discard_residue(task, worktree_path, marker)
        before = worktree_status(worktree_path)
        dirty_paths = before.fetch("entries").map { |entry| entry.fetch("path") }
        requested = discard_paths(task, marker, dirty_paths)
        unknown = requested - dirty_paths
        unless unknown.empty?
          raise Hive::UsageError,
                "refusing to discard paths not currently reported as residue: #{display_paths(unknown).join(', ')}"
        end

        restore_paths!(worktree_path, requested)
        status_payload(task, worktree_path, action: "discard-residue").merge(
          "discarded_paths" => display_paths(requested)
        )
      end

      def discard_paths(task, marker, current_paths)
        paths = if Array(@paths).empty?
          marker_residue_paths(task, marker, current_paths)
        else
          Array(@paths).map(&:to_s)
        end
        paths = paths.reject(&:empty?).uniq
        raise Hive::UsageError, "no residue paths supplied or recorded on the marker" if paths.empty?

        normalized = paths.map { |path| Hive::Stages::AutoCommit.normalize_recovery_path(path) }
        if normalized.any?(&:nil?)
          raise Hive::UsageError, "--paths must contain only normalized repository-relative paths"
        end
        normalized
      end

      def marker_residue_paths(task, marker, current_paths)
        if marker.attrs["residue_paths_b64"] || marker.attrs["residue_paths_file"] ||
           marker.attrs["residue_paths_sha256"]
          return Hive::Stages::CleanExit.recovery_paths(
            marker.attrs, task_folder: task.folder, current_paths: current_paths
          )
        end

        marker.attrs["residue_paths"].to_s.split(",").map(&:strip)
      end

      def restore_paths!(worktree_path, paths)
        head_paths = git_capture(
          worktree_path, "ls-tree", "-r", "--name-only", "-z", "HEAD",
          label: "git ls-tree HEAD"
        ).split("\0").to_h { |path| [ path, true ] }
        tracked, untracked = paths.partition { |path| head_paths.key?(path) }

        unless tracked.empty?
          git_capture(
            worktree_path, "restore", "--source=HEAD", "--staged", "--worktree", "--", *tracked,
            label: "git restore residue paths"
          )
        end
        return if untracked.empty?

        git_capture(worktree_path, "reset", "--quiet", "HEAD", "--", *untracked,
                    label: "git reset residue paths")
        git_capture(worktree_path, "clean", "-f", "--", *untracked,
                    label: "git clean residue paths")
      end

      def status_payload(task, worktree_path, action:)
        status = worktree_status(worktree_path)
        display_entries = status.fetch("entries").map do |entry|
          entry.merge("path" => display_path(entry.fetch("path")))
        end
        {
          "schema" => envelope_schema,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(envelope_schema),
          "ok" => true,
          "action" => action,
          "slug" => task.slug,
          "stage" => "#{task.stage_index}-#{task.stage_name}",
          "task_folder" => task.folder,
          "worktree_path" => worktree_path,
          "branch" => git_capture(worktree_path, "branch", "--show-current", label: "git branch --show-current").strip,
          "head" => git_capture(worktree_path, "rev-parse", "HEAD", label: "git rev-parse HEAD").strip,
          "clean" => status.fetch("entries").empty?,
          "untracked_count" => status.fetch("entries").count { |entry| entry.fetch("status") == "??" },
          "residue_paths" => display_paths(status.fetch("entries").map { |entry| entry.fetch("path") }),
          "porcelain" => display_entries,
          "next_action" => {
            "kind" => "refresh_status",
            "command" => "hive status --json",
            "instructions" => "refresh status, then use its generation-guarded workflow.retry action"
          }
        }
      end

      def worktree_status(worktree_path)
        raw = git_capture(
          worktree_path, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames",
          label: "git status --porcelain"
        )
        entries = raw.split("\0").filter_map do |record|
          next if record.empty?
          unless record.bytesize >= 4 && record.getbyte(2) == 32
            raise Hive::WorktreeError, "git status returned malformed porcelain data"
          end

          path = record.byteslice(3..).to_s.force_encoding(Encoding::UTF_8)
          raise Hive::WorktreeError, "git status returned a non-UTF-8 path" unless path.valid_encoding?

          { "status" => record.byteslice(0, 2), "path" => path }
        end
        { "entries" => entries }
      end

      def git_capture(worktree_path, *args, label:)
        result = Hive::Stages::AutoCommit.capture_git_with_timeout(
          [ "git", "--literal-pathspecs", "-C", worktree_path, *args ], label: label
        )
        raise Hive::WorktreeError, display_message(result[:message]) unless result[:success]

        result[:stdout].to_s
      end

      def display_paths(paths)
        Array(paths).map { |path| display_path(path) }.uniq
      end

      def display_path(path)
        Hive::Events.clean_exit_paths([ path ]).fetch(0)
      end

      def display_message(message)
        Hive::SecretPatterns.redact(message.to_s)
      end

      def render_text(payload)
        puts "#{payload.fetch('slug')}: #{payload.fetch('action')}"
        puts "  worktree: #{payload.fetch('worktree_path')}"
        puts "  branch: #{payload.fetch('branch')}"
        puts "  head: #{payload.fetch('head')}"
        puts "  residue: #{payload.fetch('residue_paths').empty? ? '(clean)' : payload.fetch('residue_paths').join(', ')}"
        puts "  next: #{payload.dig('next_action', 'command')}"
      end
    end
  end
end
