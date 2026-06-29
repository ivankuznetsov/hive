require "hive/brainstorm_parser"
require "hive/git_ops"
require "hive/worktree"

module Hive
  module Daemon
    # Fail-closed guard before clearing a terminal ERROR for same-stage rerun.
    module AutoRetrySafety
      SUCCESS_MARKERS = %w[complete execute_complete review_complete].freeze
      FEEDBACK_PATTERN = /\b(user\s+feedback|feedback|requested\s+change|operator\s+feedback)\b/i.freeze

      module_function

      def safe_to_retry?(row)
        return [ false, "terminal success marker present" ] if SUCCESS_MARKERS.include?(row.marker.to_s)

        case row.stage.to_s
        when "4-execute"
          execute_safe?(row)
        when "2-brainstorm"
          brainstorm_safe?(row)
        when "3-plan"
          plan_safe?(row)
        else
          # Fail CLOSED for any stage without a bespoke work-area check. A
          # category like :claude_launcher can be classified on a marker in
          # ANY stage, and "when uncertain, do not retry" (plan R8) governs:
          # we will not blind-clear a terminal error in a stage whose
          # re-entry safety we have not verified here.
          [ false, "no work-area safety check for stage #{row.stage}" ]
        end
      rescue StandardError => e
        [ false, "inspection failed: #{e.class}: #{e.message}" ]
      end

      def execute_safe?(row)
        pointer = Hive::Worktree.read_pointer(row.folder.to_s)
        path = pointer ? pointer["path"].to_s : ""
        return [ false, "missing worktree pointer" ] if path.empty?
        return [ false, "worktree missing" ] unless File.directory?(path)

        status = Hive::GitOps.new(path).status_short
        return [ true, "worktree clean" ] if status.to_s.strip.empty?

        [ false, "worktree dirty" ]
      end

      def brainstorm_safe?(row)
        path = File.join(row.folder.to_s, "brainstorm.md")
        questions = Hive::BrainstormParser.parse(path)
        answered = questions.any?(&:answered?)
        return [ false, "brainstorm answers present" ] if answered

        [ true, "no brainstorm answers present" ]
      end

      def plan_safe?(row)
        path = File.join(row.folder.to_s, "plan.md")
        return [ true, "plan.md absent" ] unless File.exist?(path)

        text = File.read(path, encoding: "UTF-8").scrub
        return [ false, "plan user feedback present" ] if text.match?(FEEDBACK_PATTERN)

        [ true, "no plan feedback detected" ]
      end

      # The per-stage helpers are implementation detail, not part of the
      # module's public surface — only `safe_to_retry?` is. Keep them off the
      # singleton's public API so a future helper that forgot to return the
      # `[bool, reason]` tuple can't be called directly and silently
      # destructure `safety_reason = nil` at an external call site.
      private_class_method :execute_safe?, :brainstorm_safe?, :plan_safe?
    end
  end
end
