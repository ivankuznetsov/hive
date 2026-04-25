require "json"
require "open3"
require "set"
require "hive"
require "hive/findings"
require "hive/task_resolver"
require "hive/lock"
require "hive/git_ops"

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
                     pass: nil, project: nil, json: false)
        @operation = operation
        @target = target
        @ids = (ids || []).map(&:to_i)
        @all = all
        @severity = severity
        @pass = pass
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
        task = Hive::TaskResolver.new(@target, project_filter: @project_filter).resolve
        review_path = Hive::Findings.review_path_for(task, pass: @pass)

        Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: @operation.to_s) do
          doc = Hive::Findings::Document.new(review_path)
          target_ids = select_target_ids(doc)
          changes = apply_toggle!(doc, target_ids)
          if changes.any?
            doc.write!
            commit_change(task, review_path, changes)
          end
          emit_report(task, review_path, doc, target_ids, changes)
        end
      end

      # Resolve the union of explicit IDs, --severity, and --all into a
      # concrete ID list. Empty result is an error: the caller asked to do
      # something but no findings matched.
      def select_target_ids(doc)
        ids = []
        ids.concat(doc.findings.map(&:id)) if @all
        ids.concat(doc.findings.select { |f| f.severity == @severity.downcase }.map(&:id)) if @severity
        ids.concat(@ids)
        ids = ids.uniq.sort

        if ids.empty?
          raise Hive::InvalidTaskPath,
                "no findings selected; pass IDs, --all, or --severity <name>"
        end

        validate_ids_exist!(doc, ids)
        ids
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

      def commit_change(task, review_path, changes)
        rel = review_path.sub("#{task.hive_state_path}/", "")
        action = "#{@operation} findings #{changes.map { |c| c['id'] }.join(',')} in #{File.basename(review_path)}"
        message = "hive: #{task.stage_index}-#{task.stage_name}/#{task.slug} #{action}"
        ops = Hive::GitOps.new(task.project_root)
        Hive::Lock.with_commit_lock(task.hive_state_path) do
          ops.run_git!("-C", task.hive_state_path, "add", "--", rel)
          _, _, status = Open3.capture3("git", "-C", task.hive_state_path, "diff", "--cached", "--quiet")
          ops.run_git!("-C", task.hive_state_path, "commit", "-m", message) unless status.success?
        end
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
          "pass" => pass_from_path(review_path),
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
          warn "next: hive run #{task.folder}"
        end
      end

      # After accept-finding, the agent's natural next step is to re-run
      # the execute stage so the implementer pass picks up the newly-
      # accepted findings. After reject, the next step is the same — the
      # reviewer's outcome is unchanged but the implementer pass already
      # reflects the up-to-date set.
      def next_action(task, doc)
        kind = Hive::Schemas::NextActionKind
        accepted = doc.summary["accepted"]
        total = doc.summary["total"]
        if accepted.zero? && total.positive?
          # Nothing accepted — the agent should mark execute_complete by
          # re-running, which counts findings and sets the marker.
          { "kind" => kind::RUN, "folder" => task.folder, "command" => "hive run #{task.folder}" }
        elsif accepted.positive?
          { "kind" => kind::RUN, "folder" => task.folder, "command" => "hive run #{task.folder}",
            "reason" => "#{accepted} accepted finding(s) need a fresh implementation pass" }
        else
          { "kind" => kind::NO_OP, "reason" => "no findings" }
        end
      end

      def pass_from_path(path)
        m = File.basename(path).match(/ce-review-(\d+)\.md/)
        m ? m[1].to_i : nil
      end

      def emit_error_envelope(error)
        payload = {
          "schema" => "hive-findings",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-findings"),
          "ok" => false,
          "operation" => @operation.to_s,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error_kind_for(error),
          "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::GENERIC,
          "message" => error.message
        }
        payload["candidates"] = error.candidates if error.is_a?(Hive::AmbiguousSlug)
        payload["id"] = error.id if error.is_a?(Hive::UnknownFinding)
        puts JSON.generate(payload)
      end

      def error_kind_for(error)
        case error
        when Hive::AmbiguousSlug then "ambiguous_slug"
        when Hive::NoReviewFile then "no_review_file"
        when Hive::UnknownFinding then "unknown_finding"
        when Hive::InvalidTaskPath then "invalid_task_path"
        else "error"
        end
      end
    end
  end
end
