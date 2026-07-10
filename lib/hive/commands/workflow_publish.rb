require "fileutils"
require "json"
require "tmpdir"
require "hive"
require "hive/config"
require "hive/commands/workflow"
require "hive/honeycomb/package_builder"
require "hive/honeycomb/preflight"
require "hive/honeycomb/submission"
require "hive/workflows/descriptor_parser"
require "hive/workflows/loader"

module Hive
  module Commands
    class WorkflowPublish
      SCHEMA = "hive-workflow-publish".freeze

      class PreflightError < Hive::Error
        attr_reader :result

        def initialize(result)
          @result = result
          super("honeycomb preflight blocked publication with #{result.findings.length} finding(s)")
        end

        def exit_code
          Hive::ExitCodes::CONFIG
        end
      end

      def initialize(id, project_root: Dir.pwd, json: false, dry_run: false, version: nil,
                     stdout: $stdout, stderr: $stderr, package_builder: nil,
                     preflight: nil, submission: nil)
        @id = id
        @project_root = File.expand_path(project_root)
        @json = json
        @dry_run = dry_run
        @version = version
        @stdout = stdout
        @stderr = stderr
        @package_builder = package_builder || Hive::Honeycomb::PackageBuilder.method(:build)
        @preflight = preflight || Hive::Honeycomb::Preflight.method(:run)
        @submission = submission || Hive::Honeycomb::Submission.method(:submit)
      end

      def call
        call!
      rescue Hive::Commands::Workflow::UsageError, PreflightError, Hive::ConfigError,
             Hive::ConcurrentRunError, Hive::Honeycomb::Submission::Error,
             Hive::GhError, SystemCallError, IOError => e
        payload = error_payload(e)
        if @json
          @stdout.puts JSON.generate(payload)
        else
          render_human_error(e)
        end
        exit(e.respond_to?(:exit_code) ? e.exit_code : Hive::ExitCodes::GENERIC)
      end

      def call!
        id = Hive::Commands::Workflow.normalize_and_validate_id!(@id)
        validate_version_override!
        cfg = Hive::Config.load(@project_root)
        descriptor_path = File.join(Hive::Workflows::Loader.workflow_dir(@project_root), "#{id}.yml")
        unless File.file?(descriptor_path)
          raise Hive::Commands::Workflow::UsageError.new(
            "unknown project workflow #{id.inspect}; expected descriptor at #{descriptor_path}",
            value: id
          )
        end

        workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)
        staging_root = Dir.mktmpdir("hive-honeycomb-publish")
        begin
          package = @package_builder.call(
            workflow: workflow,
            descriptor_path: descriptor_path,
            output_dir: staging_root,
            version: @version,
            cfg: cfg
          )
          preflight = @preflight.call(package: package, project_root: @project_root, cfg: cfg)
          raise PreflightError, preflight unless preflight.success?

          package = preflight.package
          submission = unless @dry_run
            @submission.call(
              package: package,
              repository: cfg.dig("honeycomb", "repository"),
              cfg: cfg
            )
          end
          payload = success_payload(package, preflight, submission, cfg)
          @json ? @stdout.puts(JSON.generate(payload)) : render_human_success(payload)
          payload
        ensure
          FileUtils.rm_rf(staging_root) if staging_root
        end
      end

      private

      def validate_version_override!
        return if @version.nil?
        return if Hive::Workflows::DescriptorParser::SEMVER.match?(@version.to_s)

        raise Hive::Commands::Workflow::UsageError.new(
          "invalid publication version #{@version.inspect}; expected strict semantic version",
          value: @version
        )
      end

      def success_payload(package, preflight, submission, cfg)
        manifest = package.manifest
        {
          "schema" => SCHEMA,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
          "ok" => true,
          "dry_run" => @dry_run,
          "id" => package.id,
          "version" => package.version,
          "file_count" => package.files.length,
          "aggregate_sha256" => manifest.fetch("aggregate_sha256"),
          "rule_sets" => manifest.fetch("rule_sets"),
          "dependencies" => package.dependencies,
          "permissions" => package.permission_summary,
          "lint_status" => preflight.status.to_s,
          "review_required_count" => preflight.review_required.length,
          "review_required" => preflight.review_required,
          "repository" => cfg.dig("honeycomb", "repository"),
          "submission_mode" => submission&.mode,
          "branch" => submission&.branch,
          "pr_url" => submission&.pr_url
        }
      end

      def render_human_success(payload)
        @stdout.puts "hive: honeycomb #{payload.fetch('id')} v#{payload.fetch('version')}"
        @stdout.puts "files: #{payload.fetch('file_count')}"
        @stdout.puts "aggregate sha256: #{payload.fetch('aggregate_sha256')}"
        rules = payload.fetch("rule_sets")
        @stdout.puts "rules: secrets v#{rules.fetch('secrets')}, deny v#{rules.fetch('deny')}"
        @stdout.puts "dependencies: #{payload.fetch('dependencies').length}"
        aggregate = payload.fetch("permissions").fetch("aggregate")
        @stdout.puts "permissions: #{Array(aggregate['presets']).join(', ')}; " \
                     "shell=#{Array(aggregate['shell_exposures']).join(', ')}"
        @stdout.puts "lint: #{payload.fetch('lint_status')} " \
                     "(review required: #{payload.fetch('review_required_count')})"
        if payload.fetch("dry_run")
          @stdout.puts "dry-run: local honeycomb complete; no remote changes"
        else
          @stdout.puts "submitted: #{payload.fetch('submission_mode')} via #{payload.fetch('branch')}"
          @stdout.puts "PR: #{payload.fetch('pr_url')}"
        end
      end

      def render_human_error(error)
        findings_for(error).each do |finding|
          location = [ finding["file"], finding["line"] ].compact.join(":")
          @stderr.puts "hive workflow publish: #{location} #{finding.fetch('rule')}: " \
                       "#{finding.fetch('remediation')}"
        end
        @stderr.puts "hive workflow publish: #{error.message}"
      rescue Errno::EPIPE
        nil
      end

      def error_payload(error)
        Hive::Schemas::ErrorEnvelope.build(
          schema: SCHEMA,
          error: error,
          error_kind: error_kind_for(error),
          extras: error_extras(error)
        )
      end

      def error_extras(error)
        extras = { "dry_run" => @dry_run }
        extras["id"] = @id.to_s unless @id.nil?
        findings = findings_for(error)
        extras["findings"] = findings unless findings.empty?
        if error.is_a?(Hive::Honeycomb::Submission::PartialError)
          extras["repository"] = error.repository
          extras["branch"] = error.branch
        end
        extras
      end

      def findings_for(error)
        return [] unless error.is_a?(PreflightError)

        error.result.findings.map do |finding|
          finding.to_h.to_h { |key, value| [ key.to_s, value ] }
        end
      end

      def error_kind_for(error)
        kinds = Hive::Schemas::WorkflowPublishErrorKind
        case error
        when Hive::Commands::Workflow::UsageError       then kinds::USAGE
        when PreflightError                             then kinds::PREFLIGHT
        when Hive::ConcurrentRunError                   then kinds::CONCURRENT_RUN
        when Hive::Honeycomb::Submission::PartialError then kinds::SUBMISSION_PARTIAL
        when Hive::Honeycomb::Submission::Error,
             Hive::GhError                             then kinds::SUBMISSION
        when Hive::ConfigError                          then kinds::CONFIG
        else                                                 kinds::ERROR
        end
      end
    end
  end
end
