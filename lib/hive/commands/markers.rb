require "fileutils"
require "json"
require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/lock"
require "hive/git_ops"
require "hive/stages"

module Hive
  module Commands
    # `hive markers SUBCOMMAND` — agent-callable surface for state-file
    # markers.
    #
    # v1 ships one subcommand: `clear FOLDER --name <NAME>`. It removes
    # the named marker line from the task's state file (atomic write)
    # and records a `hive_commit` so the audit trail stays accurate.
    #
    # Recovery from `REVIEW_STALE` / `REVIEW_CI_STALE` / `REVIEW_ERROR`
    # / `EXECUTE_STALE` / `EXECUTE_ERROR` previously required the user
    # to hand-edit `task.md` and delete the marker comment. The runner's
    # pre-flight `warn` told the user "remove the marker, then re-run"
    # but the action surface was prose. This command turns that prose
    # into a deterministic call.
    #
    # Terminal-success markers (`REVIEW_COMPLETE` / `EXECUTE_COMPLETE` /
    # `COMPLETE`) are deliberately excluded from the allowlist — those
    # markers gate `hive approve`'s forward-advance check, and clearing
    # them silently would let an agent skip the approval gesture.
    class Markers
      # Markers that map to a "user / agent stuck on a recoverable
      # error" runner pre-flight branch. Keep this list in sync with
      # the `case marker.name` in `lib/hive/stages/review.rb` and the
      # equivalent stale paths in `lib/hive/stages/execute.rb`.
      ALLOWED_NAMES = %w[
        REVIEW_STALE
        REVIEW_CI_STALE
        REVIEW_ERROR
        EXECUTE_STALE
        ERROR
      ].freeze

      VALID_SUBCOMMANDS = %w[clear].freeze

      def initialize(subcommand, target = nil, name: nil, project: nil, json: false)
        @subcommand = subcommand
        @target = target
        @name = name
        @project_filter = project
        @json = json
      end

      def call
        do_call
      rescue Hive::Error => e
        emit_error_envelope(e) if @json
        raise
      rescue StandardError => e
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_error_envelope(wrapped) if @json
        raise wrapped
      end

      private

      def do_call
        unless VALID_SUBCOMMANDS.include?(@subcommand)
          raise Hive::InvalidTaskPath,
                "hive markers: unknown subcommand #{@subcommand.inspect} " \
                "(expected: #{VALID_SUBCOMMANDS.join(', ')})"
        end

        clear_marker
      end

      def clear_marker
        if @target.nil? || @target.to_s.strip.empty?
          raise Hive::InvalidTaskPath,
                "hive markers clear: missing FOLDER argument"
        end
        if @name.nil? || @name.to_s.strip.empty?
          raise Hive::InvalidTaskPath,
                "hive markers clear: missing --name <MARKER_NAME>"
        end

        normalized = @name.to_s.upcase
        unless ALLOWED_NAMES.include?(normalized)
          raise Hive::WrongStage,
                "hive markers clear: marker #{normalized.inspect} is not in the allowlist " \
                "(#{ALLOWED_NAMES.join(', ')}). Terminal-success markers " \
                "(REVIEW_COMPLETE / EXECUTE_COMPLETE / COMPLETE) cannot be cleared this way; " \
                "use `hive approve` to advance the task or move the folder backward via `hive approve --to <stage>`."
        end

        folder = resolve_target
        task = Hive::Task.new(folder)
        validate_project_path_match!(task)

        marker = Hive::Markers.current(task.state_file)
        actual = marker.name.to_s.upcase
        unless actual == normalized
          raise Hive::WrongStage,
                "hive markers clear: task #{task.slug} has marker #{actual.inspect}, " \
                "not #{normalized.inspect}; refusing to clear (the file may have been edited)."
        end

        remove_marker_line!(task.state_file, marker.raw)
        record_hive_commit(task, normalized)
        emit_success(task, normalized)
      end

      # Atomic removal: read body, drop the matched marker substring
      # and any trailing newline that the marker occupied alone on a
      # line, then `Markers.write_atomic` the result. Mirrors the same
      # safety guarantees as Markers.set's atomic write path.
      def remove_marker_line!(state_file, raw_marker)
        return unless File.exist?(state_file)

        body = File.read(state_file, encoding: "UTF-8")
        # Match the marker plus, optionally, a trailing newline if the
        # marker sat on its own line (don't strip a newline that's
        # part of surrounding prose). Anchor on Regexp.escape to match
        # the exact marker comment we read.
        cleaned = body.sub(/#{Regexp.escape(raw_marker)}\n?/, "")
        Hive::Markers.write_atomic(state_file, cleaned)
      end

      def record_hive_commit(task, normalized)
        ops = Hive::GitOps.new(task.project_root)
        action = "markers clear #{normalized}"
        ops.hive_commit(stage_name: "#{task.stage_index}-#{task.stage_name}",
                        slug: task.slug,
                        action: action)
      end

      # ── Resolution (mirrors Hive::Commands::Approve) ─────────────────────

      def resolve_target
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

      def validate_project_path_match!(task)
        return unless @project_filter
        return unless path_target?

        matching = Hive::Config.registered_projects.find { |p| p["path"] == task.project_root }
        actual_name = matching ? matching["name"] : File.basename(task.project_root)
        return if actual_name == @project_filter

        raise Hive::InvalidTaskPath,
              "FOLDER path is in project '#{actual_name}' but --project says '#{@project_filter}'"
      end

      # ── Reporting ────────────────────────────────────────────────────────

      def emit_success(task, normalized)
        if @json
          payload = {
            "schema" => "hive-markers-clear",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-markers-clear"),
            "ok" => true,
            "folder" => task.folder,
            "slug" => task.slug,
            "marker_cleared" => normalized
          }
          puts JSON.generate(payload)
        else
          puts "hive: cleared #{normalized} from #{task.slug}"
          warn "next: hive run #{task.folder}"
        end
      end

      def emit_error_envelope(error)
        payload = {
          "schema" => "hive-markers-clear",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-markers-clear"),
          "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error_kind_for(error),
          "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::GENERIC,
          "message" => error.message
        }
        payload["candidates"] = error.candidates if error.is_a?(Hive::AmbiguousSlug)
        puts JSON.generate(payload)
      end

      def error_kind_for(error)
        case error
        when Hive::AmbiguousSlug then "ambiguous_slug"
        when Hive::WrongStage then "wrong_stage"
        when Hive::InvalidTaskPath then "invalid_task_path"
        else "error"
        end
      end
    end
  end
end
