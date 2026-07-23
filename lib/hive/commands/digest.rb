require "json"
require "hive/digest"

module Hive
  module Commands
    class Digest
      def initialize(date: nil, dry_run: false, json: false, runner: Hive::Digest,
                     output: $stdout, repos: [])
        @date = date
        @dry_run = dry_run
        @json = json
        @runner = runner
        @output = output
        @repos = Array(repos)
      end

      def call
        result = @runner.run(date: parse_date, dry_run: @dry_run, repos: @repos)
        emit(result)
        result
      rescue Hive::Error => e
        emit_error_envelope(e) if @json
        raise
      rescue StandardError => e
        error = Hive::InternalError.new("hive digest: internal error: #{e.class}: #{e.message}")
        emit_error_envelope(error) if @json
        raise error
      end

      private

      def parse_date
        return nil if @date.to_s.empty?

        unless @date.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          raise Hive::ConfigError, "hive digest: --date must be YYYY-MM-DD; got #{@date.inspect}"
        end

        Hive::Digest::LondonWindow.parse_date(@date)
      rescue ArgumentError
        raise Hive::ConfigError, "hive digest: --date must be YYYY-MM-DD; got #{@date.inspect}"
      end

      def emit(result)
        if @json
          @output.puts JSON.generate(json_payload(result))
        elsif @dry_run
          @output.puts result.message
        else
          @output.puts "hive digest: #{result.status} for #{result.date.iso8601} " \
                       "(#{result.projects.size} projects, #{result.pr_count} PRs)"
        end
      end

      def json_payload(result)
        payload = {
          "ok" => true,
          "schema" => "hive-digest",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-digest"),
          "date" => result.date.iso8601,
          "status" => result.status.to_s,
          "dry_run" => result.dry_run,
          "resolved_repository_count" => result.resolved_repository_count,
          "collected_repository_count" => result.collected_repository_count,
          "project_count" => result.projects.size,
          "pr_count" => result.pr_count,
          "projects" => result.projects.map { |project| project_payload(project, result.stats) },
          "warnings" => result.warnings.map(&:to_h),
          "chat_id" => result.delivery&.chat_id,
          "message" => result.dry_run ? result.message : nil
        }
        add_known_metrics(payload, result.stats.overall)
      end

      def project_payload(project, stats)
        repository = project.repository.target.repository
        aggregate = stats.by_repository.fetch(project.repository.target.key)
        payload = {
          "repository" => repository,
          "description" => project.significance,
          "pr_count" => project.pull_requests.size,
          "prs" => project.pull_requests.map do |generated_pr|
            pr_payload(generated_pr)
          end
        }
        add_known_metrics(payload, aggregate)
      end

      def pr_payload(generated_pr)
        pr = generated_pr.pull_request
        pr.to_h.merge("bullets" => generated_pr.bullets.map(&:text))
      end

      def add_known_metrics(payload, aggregate)
        Hive::Digest::PR_METRICS.each do |metric|
          value = aggregate.metric(metric).value
          payload[metric.to_s] = value unless value.nil?
        end
        payload
      end

      def emit_error_envelope(error)
        @output.puts JSON.generate(
          "schema" => "hive-digest",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-digest"),
          "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error.is_a?(Hive::ConfigError) ? "config" : "internal",
          "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::SOFTWARE,
          "message" => error.message
        )
      end
    end
  end
end
