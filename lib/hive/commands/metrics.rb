require "json"
require "hive/config"
require "hive/metrics"

module Hive
  module Commands
    # `hive metrics rollback-rate [--days N] [--project NAME] [--json]`.
    #
    # See lib/hive/metrics.rb for the trailer + revert-detection rules.
    class Metrics
      # Typed usage error for hive metrics. Exits with the canonical
      # sysexits(3) USAGE code (64) — distinct from
      # ExitCodes::ALREADY_INITIALIZED (2), which the metrics command
      # was previously colliding with.
      class UsageError < Hive::Error
        attr_reader :error_kind

        def initialize(message, error_kind:)
          super(message)
          @error_kind = error_kind
        end

        def exit_code
          Hive::ExitCodes::USAGE
        end
      end

      def initialize(subcommand, days: nil, project: nil, json: false)
        @subcommand = subcommand
        @days = days
        @project = project
        @json = json
        validate_days! unless @days.nil?
      end

      # `--days N` must be a positive integer. Thor coerces with `to_f`
      # for `type: :numeric`, so a value like `--days 1.5` arrives here
      # as a Float. Reject non-integer numeric values, zero, and
      # negatives; let the typed UsageError propagate so the JSON
      # envelope path emits the documented error_kind.
      def validate_days!
        valid = @days.is_a?(Integer) || (@days.respond_to?(:to_i) && @days.to_i == @days)
        positive = valid && @days > 0
        return if positive

        fail_usage!(
          "hive metrics: --days must be a positive integer (got #{@days.inspect})",
          kind: "invalid_days"
        )
      end

      def call
        case @subcommand
        when "rollback-rate", nil
          run_rollback_rate
        else
          fail_usage!(
            "hive metrics: unknown subcommand #{@subcommand.inspect} (expected: rollback-rate)",
            kind: "unknown_subcommand"
          )
        end
      end

      def run_rollback_rate
        roots = resolve_project_roots
        if roots.empty?
          if @project
            fail_usage!("hive metrics: unknown project: #{@project}", kind: "unknown_project")
          else
            fail_usage!(
              "hive metrics: no projects registered; run `hive init <path>` first",
              kind: "no_projects_registered"
            )
          end
        end

        since = @days ? "#{@days} days ago" : nil
        per_project = roots.map do |entry|
          stats = Hive::Metrics.rollback_rate(entry["path"], since: since)
          stats.merge("project" => entry["name"])
        end

        if @json
          puts JSON.generate(json_payload(per_project, since))
        else
          render_text(per_project, since)
        end
      end

      # Emit a JSON error envelope on stdout (mirrors the
      # `Hive::Commands::Approve#emit_error_envelope` pattern) when --json
      # is on, then raise the typed Hive::Error so bin/hive's rescue path
      # produces the documented USAGE (64) exit code.
      def fail_usage!(message, kind:)
        error = UsageError.new(message, error_kind: kind)
        if @json
          puts JSON.generate(
            "schema" => "hive-metrics-rollback-rate",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-metrics-rollback-rate"),
            "ok" => false,
            "error_kind" => kind,
            "exit_code" => Hive::ExitCodes::USAGE,
            "message" => message
          )
        else
          warn message
        end
        raise error
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
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-metrics-rollback-rate"),
          "since" => since,
          "projects" => per_project.map { |stats| project_json(stats) }
        }
      end

      def project_json(stats)
        {
          "project" => stats["project"],
          "project_root" => stats["project_root"],
          "total_fix_commits" => stats["total_fix_commits"],
          "reverted_commits" => stats["reverted_commits"],
          "rollback_rate" => stats["rollback_rate"],
          "by_bias" => stats["by_bias"],
          "by_phase" => stats["by_phase"]
        }
      end

      def render_text(per_project, since)
        header = since ? "rollback-rate over the last #{@days} days" : "rollback-rate (full history)"
        puts header
        puts "=" * header.length
        per_project.each do |stats|
          puts "\n#{stats['project']} (#{stats['project_root']})"
          puts "  total fix commits: #{stats['total_fix_commits']}"
          puts "  reverted:          #{stats['reverted_commits']}"
          puts "  rate:              #{format('%.2f%%', stats['rollback_rate'] * 100)}"
          render_bucket("by bias", stats["by_bias"])
          render_bucket("by phase", stats["by_phase"])
        end
      end

      def render_bucket(label, bucket)
        return if bucket.empty?

        puts "  #{label}:"
        bucket.each do |k, v|
          puts "    #{k}: total=#{v['total']} reverted=#{v['reverted']} rate=#{format('%.2f%%', v['rate'] * 100)}"
        end
      end
    end
  end
end
