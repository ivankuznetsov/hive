require "json"
require "hive/config"
require "hive/metrics"

module Hive
  module Commands
    # `hive metrics rollback-rate [--days N] [--project NAME] [--json]`.
    #
    # See lib/hive/metrics.rb for the trailer + revert-detection rules.
    class Metrics
      EXIT_OK = 0
      EXIT_USAGE = 2

      def initialize(subcommand, days: nil, project: nil, json: false)
        @subcommand = subcommand
        @days = days
        @project = project
        @json = json
      end

      def call
        case @subcommand
        when "rollback-rate", nil
          run_rollback_rate
        else
          warn "hive metrics: unknown subcommand #{@subcommand.inspect} (expected: rollback-rate)"
          exit EXIT_USAGE
        end
      end

      def run_rollback_rate
        roots = resolve_project_roots
        if roots.empty?
          if @project
            warn "hive metrics: unknown project: #{@project}"
            exit EXIT_USAGE
          else
            warn "hive metrics: no projects registered; run `hive init <path>` first"
            exit EXIT_USAGE
          end
        end

        since = @days ? "#{@days} days ago" : nil
        per_project = roots.map do |entry|
          stats = Hive::Metrics.rollback_rate(entry["path"], since: since)
          stats.merge(project: entry["name"])
        end

        if @json
          puts JSON.generate(json_payload(per_project, since))
        else
          render_text(per_project, since)
        end
      end

      def resolve_project_roots
        projects = Hive::Config.registered_projects
        return projects if @project.nil?

        match = projects.find { |p| p["name"] == @project }
        match ? [ match ] : []
      end

      def json_payload(per_project, since)
        {
          "schema" => "hive-metrics-rollback-rate",
          "schema_version" => 1,
          "since" => since,
          "projects" => per_project.map { |stats| project_json(stats) }
        }
      end

      def project_json(stats)
        {
          "project" => stats[:project],
          "project_root" => stats[:project_root],
          "total_fix_commits" => stats[:total_fix_commits],
          "reverted_commits" => stats[:reverted_commits],
          "rollback_rate" => stats[:rollback_rate],
          "by_bias" => stringify_bucket(stats[:by_bias]),
          "by_phase" => stringify_bucket(stats[:by_phase])
        }
      end

      def stringify_bucket(bucket)
        bucket.transform_values do |v|
          { "total" => v[:total], "reverted" => v[:reverted], "rate" => v[:rate] }
        end
      end

      def render_text(per_project, since)
        header = since ? "rollback-rate over the last #{@days} days" : "rollback-rate (full history)"
        puts header
        puts "=" * header.length
        per_project.each do |stats|
          puts "\n#{stats[:project]} (#{stats[:project_root]})"
          puts "  total fix commits: #{stats[:total_fix_commits]}"
          puts "  reverted:          #{stats[:reverted_commits]}"
          puts "  rate:              #{format('%.2f%%', stats[:rollback_rate] * 100)}"
          render_bucket("by bias", stats[:by_bias])
          render_bucket("by phase", stats[:by_phase])
        end
      end

      def render_bucket(label, bucket)
        return if bucket.empty?

        puts "  #{label}:"
        bucket.each do |k, v|
          puts "    #{k}: total=#{v[:total]} reverted=#{v[:reverted]} rate=#{format('%.2f%%', v[:rate] * 100)}"
        end
      end
    end
  end
end
