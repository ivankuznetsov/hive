require "json"
require "open3"
require "set"
require "hive"
require "hive/findings"
require "hive/task_resolver"
require "hive/lock"
require "hive/git_ops"
require "hive/commit_or_rollback"

module Hive
  module Commands
    # Shared implementation for `hive accept-finding` and
    # `hive reject-finding`. Both commands toggle GFM-checkbox state on
    # findings in `reviews/ce-review-NN.md`; they differ only in which
    # state they set.
    #
    # Filter combinators (`ids`, `--all`, `--severity`) are unioned: an
    # invocation like `accept-finding TARGET 3 --severity high` accepts
    # finding 3 plus every finding in the High section.
    class FindingToggle
      ACCEPT = :accept
      REJECT = :reject

      def initialize(operation, target, ids: [], all: false, severity: nil,
                     pass: nil, project: nil, stage: nil, json: false)
        @operation = operation
        @target = target
        @ids = ids || []
        @all = all
        @severity = severity
        @pass = pass
        @project_filter = project
        @stage_filter = stage
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

      # Locking strategy mirrors `Hive::Commands::Approve`:
      #   - commit_lock OUTERMOST so contention surfaces before any FS
      #     mutation and the lock order matches approve's (preventing the
      #     deadlock where one command holds task_lock and the other
      #     holds commit_lock).
      #   - task_lock INNER blocks a concurrent `hive run` on the same
      #     task while we read + mutate the review file.
      def do_call
        task = Hive::TaskResolver.new(
          @target,
          project_filter: @project_filter,
          stage_filter: @stage_filter
        ).resolve
        review_path = Hive::Findings.review_path_for(task, pass: @pass)

        Hive::Lock.with_commit_lock(task.hive_state_path) do
          Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: @operation.to_s) do
            doc = Hive::Findings::Document.new(review_path)
            target_ids = select_target_ids(doc)
            changes = apply_toggle!(doc, target_ids)
            write_and_commit_change(task, review_path, doc, changes) if changes.any?
            emit_report(task, review_path, doc, target_ids, changes)
          end
        end
      end

      # Resolve the union of explicit IDs, --severity, and --all into a
      # concrete ID list. Empty result is an error: the caller asked to do
      # something but no findings matched.
      def select_target_ids(doc)
        ids = []
        ids.concat(doc.findings.map(&:id)) if @all
        ids.concat(doc.findings.select { |f| f.severity == @severity.downcase }.map(&:id)) if @severity
        ids.concat(parsed_ids)
        ids = ids.uniq.sort

        raise Hive::NoSelection, no_selection_message(doc) if ids.empty?

        validate_ids_exist!(doc, ids)
        ids
      end

      def no_selection_message(doc)
        if @all && doc.findings.empty?
          "review file has no findings: #{doc.path}"
        elsif @severity && doc.findings.none? { |f| f.severity == @severity.downcase }
          "no findings with severity '#{@severity}'; available: #{doc.findings.map(&:severity).compact.uniq.sort.inspect}"
        else
          "no findings selected; pass IDs, --all, or --severity <name>"
        end
      end

      def parsed_ids
        @ids.map do |id|
          text = id.to_s
          unless text.match?(/\A[1-9]\d*\z/)
            raise Hive::InvalidTaskPath,
                  "invalid finding id '#{id}'; IDs must be positive integers"
          end

          text.to_i
        end
      end

      def validate_ids_exist!(doc, ids)
        known = doc.findings.map(&:id).to_set
        missing = ids.reject { |i| known.include?(i) }
        return if missing.empty?

        raise Hive::UnknownFinding.new(
          "no finding with id=#{missing.first} in #{doc.path} (valid: #{known.to_a.sort.inspect})",
          id: missing.first
        )
      end

      # Returns an array of {id:, severity:, was:, now:} for findings whose
      # state actually changed (i.e. dropping no-ops). Idempotent reaccept
      # of an already-accepted finding produces no change entry.
      def apply_toggle!(doc, ids)
        accepted = (@operation == ACCEPT)
        ids.filter_map do |id|
          before = doc.findings.find { |f| f.id == id }
          next nil if before.accepted == accepted

          doc.toggle!(id, accepted: accepted)
          { "id" => id, "severity" => before.severity,
            "was" => before.accepted, "now" => accepted }
        end
      end

      def write_and_commit_change(task, review_path, doc, changes)
        original = File.binread(review_path)
        doc.write!
        commit_change(task, review_path, changes)
      rescue Hive::Error, SystemCallError => e
        rollback_review_change!(task, review_path, original, e)
      end

      def commit_change(task, review_path, changes)
        rel = review_path.sub("#{task.hive_state_path}/", "")
        action = "#{@operation} findings #{changes.map { |c| c['id'] }.join(',')} in #{File.basename(review_path)}"
        message = "hive: #{task.stage_index}-#{task.stage_name}/#{task.slug} #{action}"
        ops = Hive::GitOps.new(task.project_root)
        ops.run_git!("-C", task.hive_state_path, "add", "--", rel)
        _, _, status = Open3.capture3("git", "-C", task.hive_state_path, "diff", "--cached", "--quiet")
        ops.run_git!("-C", task.hive_state_path, "commit", "-m", message) unless status.success?
      end

      def rollback_review_change!(task, review_path, original, original_error)
        rel = review_path.sub("#{task.hive_state_path}/", "")
        ops = Hive::GitOps.new(task.project_root)

        Hive::CommitOrRollback.attempt!(
          original_error,
          on_undo: lambda do
            File.binwrite(review_path, original)
            ops.run_git!("-C", task.hive_state_path, "reset", "--", rel)
          end,
          rolled_back_message: lambda do |e|
            "finding toggle aborted; review file rolled back. " \
              "underlying: #{e.class}: #{e.message}"
          end,
          rollback_failed_message: lambda do |orig, rb|
            "finding toggle aborted AND rollback failed. " \
              "review file: #{review_path}. " \
              "commit error: #{orig.class}: #{orig.message}. " \
              "rollback error: #{rb.class}: #{rb.message}"
          end
        )
      end

      def emit_report(task, review_path, doc, target_ids, changes)
        if @json
          puts JSON.generate(success_payload(task, review_path, doc, target_ids, changes))
        else
          render_text(task, review_path, target_ids, changes)
        end
      end

      def success_payload(task, review_path, doc, target_ids, changes)
        {
          "schema" => "hive-findings",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-findings"),
          "ok" => true,
          "operation" => @operation.to_s,
          "slug" => task.slug,
          "review_file" => review_path,
          "pass" => Hive::Findings.pass_from_path(review_path),
          "selected_ids" => target_ids,
          "changes" => changes,
          "noop" => changes.empty?,
          "summary" => doc.summary,
          "next_action" => next_action(task, doc)
        }
      end

      def render_text(task, review_path, target_ids, changes)
        verb = @operation == ACCEPT ? "accepted" : "rejected"
        puts "hive: #{verb} #{changes.size}/#{target_ids.size} finding(s) in #{File.basename(review_path)}"
        changes.each { |c| puts "  ##{c['id']} (#{c['severity'] || 'unknown'}): #{c['was']} -> #{c['now']}" }
        if changes.empty?
          puts "  (no-op: every selected finding was already #{verb})"
        else
          warn "next: hive develop #{task.slug}"
        end
      end

      # Both `kind: run` branches carry a `reason` so consumers see a
      # consistent shape. The agent's natural next step is the same in
      # both cases — re-run the execute stage; only the rationale differs.
      def next_action(task, doc)
        kind = Hive::Schemas::NextActionKind
        accepted = doc.summary["accepted"]
        total = doc.summary["total"]

        return { "kind" => kind::NO_OP, "reason" => "no findings" } if total.zero?

        reason = if accepted.positive?
          "#{accepted} accepted finding(s) need a fresh implementation pass"
        else
          "no accepted findings; re-run to mark execute_complete"
        end
        { "kind" => kind::RUN, "folder" => task.folder,
          "command" => "hive develop #{task.slug}", "reason" => reason }
      end

      def emit_error_envelope(error)
        payload = Hive::Schemas::ErrorEnvelope.build(
          schema: "hive-findings",
          error: error,
          error_kind: error_kind_for(error),
          extras: { "operation" => @operation.to_s }
        )
        puts JSON.generate(payload)
      end

      def error_kind_for(error)
        case error
        when Hive::AmbiguousSlug then "ambiguous_slug"
        when Hive::NoReviewFile then "no_review_file"
        when Hive::UnknownFinding then "unknown_finding"
        when Hive::NoSelection then "no_selection"
        when Hive::RollbackFailed then "rollback_failed"
        when Hive::InvalidTaskPath then "invalid_task_path"
        else "error"
        end
      end
    end
  end
end
