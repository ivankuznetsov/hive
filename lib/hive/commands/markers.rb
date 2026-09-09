require "fileutils"
require "json"
require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/task_resolver"
require "hive/lock"
require "hive/git_ops"

module Hive
  module Commands
    # `hive markers SUBCOMMAND` — agent-callable surface for state-file
    # markers.
    #
    # v1 ships one subcommand: `clear FOLDER --name <NAME>`. It validates
    # the named current marker, removes all marker history from the task's
    # state file (atomic write), and records a `hive_commit` so the audit
    # trail stays accurate. Purging shadowed history prevents a completed
    # run's older working/error marker from becoming current after recovery.
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
      include Hive::Schemas::EnvelopeEmitter

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

      def initialize(subcommand, target = nil, name: nil, project: nil, match_attr: nil, json: false)
        @subcommand = subcommand
        @target = target
        @name = name
        @project_filter = project
        @match_attr = match_attr
        @json = json
      end

      def call
        call_with_envelope { do_call }
      end

      def envelope_schema
        "hive-markers-clear"
      end

      def envelope_error_kind(error)
        error_kind_for(error)
      end

      def envelope_serialization_failure_policy = :raise

      private

      # The published v1 error schema deliberately exposes only the marker
      # command's original fields. Commit-lock diagnostics remain on stderr
      # and in the typed exception instead of widening this closed payload.
      def envelope_payload_for(error)
        super.tap do |payload|
          payload.delete("holder")
          payload.delete("lock_path")
        end
      end

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

        task = resolve_task

        # The global order is commit lock -> task lease -> marker mutex. Keep
        # observation, validation, rewrite, and commit inside all three so a
        # replacement runner cannot publish or move the task mid-repair.
        Hive::Lock.with_commit_lock(task.hive_state_path) do
          Hive::Lock.with_task_lock(
            task.folder, "owner" => "markers", "operation" => "clear", create: false
          ) do
            Hive::Markers.with_markers_lock(task.state_file) do
              marker = Hive::Markers.current(task.state_file)
              actual = marker.name.to_s.upcase
              unless actual == normalized
                raise Hive::WrongStage,
                      "hive markers clear: task #{task.slug} has marker #{actual.inspect}, " \
                      "not #{normalized.inspect}; refusing to clear (the file may have been edited)."
              end

              match_attr_or_raise!(task, marker)
              Hive::Markers.remove_all_markers(task.state_file)
              record_hive_commit(task, normalized)
            end
          end
        end

        emit_success(task, normalized)
      end

      # Cross-process race guard for explicit low-level operator repair.
      # If a concurrent `hive run` writes a fresh marker between observation
      # and this command, name-only matching is insufficient. `--match-attr
      # marker_id=<observed>` binds the clear to the generated occurrence.
      # Automated recovery never invokes this command; it uses the coordinator.
      def match_attr_or_raise!(task, marker)
        return if @match_attr.nil? || @match_attr.to_s.strip.empty?

        parse_match_attrs.each do |key, value|
          actual_value = marker.attrs[key]
          next if actual_value.to_s == value.to_s

          raise Hive::WrongStage,
                "hive markers clear: task #{task.slug} has marker " \
                "#{marker.name.to_s.upcase} but attr #{key.inspect}=" \
                "#{actual_value.inspect}, not #{value.inspect}; refusing " \
                "to clear (a concurrent writer likely updated the marker)."
        end
      end

      def parse_match_attrs
        @match_attr.to_s.split(",").map(&:strip).map do |pair|
          key, value = pair.split("=", 2)
          if key.nil? || key.empty? || value.nil?
            raise Hive::InvalidTaskPath,
                  "hive markers clear: --match-attr expects KEY=VALUE" \
                  " or comma-separated KEY=VALUE pairs (got #{@match_attr.inspect})"
          end

          [ key, value ]
        end
      end

      def record_hive_commit(task, normalized)
        ops = Hive::GitOps.new(task.project_root)
        action = "markers clear #{normalized}"
        ops.hive_commit(stage_name: "#{task.stage_index}-#{task.stage_name}",
                        slug: task.slug,
                        action: action)
      end

      # ── Resolution ───────────────────────────────────────────────────────

      # Delegates to the shared Hive::TaskResolver so path validation, slug/id
      # lookup, ambiguity handling, and `--project` mismatch rules stay defined
      # in one place — and so slug scans walk the project's registered workflow
      # stage union (including runtime-registered descriptors) rather than the
      # legacy coding-only `Hive::Stages::DIRS` list.
      def resolve_task
        Hive::TaskResolver.new(@target, project_filter: @project_filter).resolve
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
