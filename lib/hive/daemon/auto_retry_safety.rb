require "hive/brainstorm_parser"
require "hive/git_ops"
require "hive/secret_patterns"
require "hive/task"
require "hive/worktree"

module Hive
  module Daemon
    # Work-area guard before clearing a durable error for a same-stage rerun.
    # It temporarily defers retries when current files prove that a blind rerun
    # would overwrite operator input or collide with uncommitted execute work.
    # Unknown stages are allowed: their runner remains responsible for
    # re-validating current state, and parking them forever would contradict
    # Hive's file-based recovery contract.
    module AutoRetrySafety
      SUCCESS_MARKERS = %w[complete execute_complete review_complete].freeze
      FEEDBACK_PATTERN = /\b(user\s+feedback|feedback|requested\s+change|operator\s+feedback)\b/i.freeze
      # coding-scoped (block): stages owning coding worktrees
      WORKTREE_STAGES = %w[4-execute 5-open-pr 6-review 8-finalize].freeze
      SECRET_REASONS = %w[secret_in_pr_body secret_scan_fetch_failed].freeze

      module_function

      def safe_to_retry?(row)
        return [ false, "terminal success marker present" ] if SUCCESS_MARKERS.include?(row.marker.to_s)
        attrs = marker_attrs(row)
        reason = attrs["reason"].to_s
        if reason.end_with?("_tampered") && attrs["restored"].to_s != "true"
          return [ false, "protected files from the tampered run were not restored" ]
        end
        if SECRET_REASONS.include?(reason)
          hits = Hive::SecretPatterns.scan(File.binread(row.state_file.to_s))
          return [ false, "credential pattern remains in the local PR source" ] if hits.any?
        end

        # coding-scoped (block): per-stage work-area safety checks are specific to the coding workflow's execute/brainstorm/plan stages
        case row.stage.to_s
        when "4-execute"
          execute_safe?(row)
        when "5-open-pr", "6-review", "8-finalize"
          owned_worktree_safe?(row).first(2)
        when "2-brainstorm"
          brainstorm_safe?(row)
        when "3-plan"
          plan_safe?(row)
        else
          [ true, "no mutable work-area guard required for stage #{row.stage}" ]
        end
      rescue StandardError => e
        [ false, "inspection failed: #{e.class}: #{e.message}" ]
      end

      def execute_safe?(row)
        pointer_path = File.join(row.folder.to_s, "worktree.yml")
        return [ true, "missing worktree pointer; runner will create it" ] unless File.exist?(pointer_path)

        safe, reason, path = owned_worktree_safe?(row)
        return [ safe, reason ] unless safe

        status = Hive::GitOps.new(path).status_short
        return [ true, "worktree clean" ] if status.to_s.strip.empty?

        [ false, "worktree dirty" ]
      end

      def owned_worktree_safe?(row)
        pointer_path = File.join(row.folder.to_s, "worktree.yml")
        unless File.exist?(pointer_path)
          return [ true, "missing worktree pointer; runner will revalidate", nil ]
        end

        task = Hive::Task.new(row.folder.to_s)
        root = Hive::Worktree.canonical_root(task.project_root)
        pointer = Hive::Worktree.read_owned_pointer(
          task.folder,
          project_root: task.project_root,
          slug: task.slug,
          expected_root: root
        )
        [ true, "worktree ownership verified", pointer.fetch("path") ]
      end

      def marker_attrs(row)
        return row.marker_attrs if row.respond_to?(:marker_attrs) && row.marker_attrs.is_a?(Hash)

        {}
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
      private_class_method :execute_safe?, :owned_worktree_safe?, :marker_attrs,
                           :brainstorm_safe?, :plan_safe?
    end
  end
end
