require "json"
require "hive"
require "hive/findings"
require "hive/task_resolver"

module Hive
  module Commands
    # `hive findings TARGET [--pass N] [--json]` — list findings in the
    # latest (or specified) review file as a table or a `hive-findings`
    # JSON document. Read-only; the agent-callable inspection step before
    # `hive accept-finding` / `hive reject-finding`.
    class Findings
      def initialize(target, pass: nil, project: nil, json: false)
        @target = target
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
        doc = Hive::Findings::Document.new(review_path)
        if @json
          puts JSON.generate(success_payload(task, review_path, doc))
        else
          render_text(task, review_path, doc)
        end
      end

      def success_payload(task, review_path, doc)
        {
          "schema" => "hive-findings",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-findings"),
          "ok" => true,
          "slug" => task.slug,
          "stage" => task.stage_name,
          "stage_dir" => "#{task.stage_index}-#{task.stage_name}",
          "task_folder" => task.folder,
          "review_file" => review_path,
          "pass" => pass_from_review_path(review_path),
          "findings" => doc.findings.map(&:to_h),
          "summary" => doc.summary
        }
      end

      def render_text(task, review_path, doc)
        puts "hive: findings for #{task.slug} (#{File.basename(review_path)})"
        if doc.findings.empty?
          puts "  no findings"
          return
        end

        current_severity = nil
        doc.findings.each do |f|
          if f.severity != current_severity
            current_severity = f.severity
            puts ""
            puts "  ## #{f.severity || 'unknown'}"
          end
          mark = f.accepted ? "[x]" : "[ ]"
          line = "    #{mark} ##{f.id} #{f.title}"
          line += ": #{f.justification}" if f.justification
          puts line
        end

        s = doc.summary
        warn ""
        warn "  total=#{s['total']} accepted=#{s['accepted']} by_severity=#{s['by_severity'].to_a.map { |k, v| "#{k}:#{v}" }.join(' ')}"
      end

      def pass_from_review_path(path)
        m = File.basename(path).match(/ce-review-(\d+)\.md/)
        m ? m[1].to_i : nil
      end

      def emit_error_envelope(error)
        payload = {
          "schema" => "hive-findings",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-findings"),
          "ok" => false,
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
