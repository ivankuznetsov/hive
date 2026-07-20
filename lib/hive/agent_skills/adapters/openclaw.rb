require "digest"
require "json"

require "hive/agent_skills"
require "hive/agent_skills/canonical_skill"
require "hive/agent_skills/directory_publisher"

module Hive
  module AgentSkills
    module Adapters
      # Read-only OpenClaw/ClawHub diagnosis. OpenClaw remains externally
      # distributed and this adapter deliberately exposes no plan or execute
      # operation.
      class OpenClaw
        TIMEOUT_SEC = 15
        CLAWHUB_REF = "@ivankuznetsov/hive-cli"
        HEALTH_PRECEDENCE = %w[conflicting incompatible unavailable stale missing healthy].freeze
        Evidence = Data.define(:expected, :native, :resolution, :health, :explanation, :remediation)

        def initialize(runner: CommandRunner.new, environment: ENV)
          @runner = runner
          @environment = environment
          @projection = CanonicalSkill.new.render("openclaw")
        end

        def inspect
          expected = expected_hash
          bin = resolved_binary
          unless bin
            return Evidence.new(
              expected: expected,
              native: { "available" => false, "bin" => "openclaw", "cli_version" => nil, "commands" => [] }.freeze,
              resolution: empty_resolution,
              health: "unavailable",
              explanation: "OpenClaw is not executable or on PATH",
              remediation: "install OpenClaw, then run `openclaw skills install #{CLAWHUB_REF}`"
            ).freeze
          end

          commands = []
          version_result = run([ bin, "--version" ], commands)
          list_result = run([ bin, "skills", "list", "--json" ], commands)
          info_result = run([ bin, "skills", "info", "hive", "--json" ], commands)
          cli_version = parse_version(version_result.stdout)
          native = {
            "available" => true,
            "bin" => bin,
            "cli_version" => cli_version,
            "commands" => commands.freeze,
            "clawhub" => nil,
            "projection" => nil
          }
          issues = []
          unless version_result.success? && cli_version
            issues << [ "incompatible", "OpenClaw version probe failed: #{command_failure(version_result)}" ]
          end
          unless list_result.success?
            issues << [ "incompatible", "OpenClaw skill inventory failed: #{command_failure(list_result)}" ]
          end

          unless info_result.success?
            issues << [ "missing", "OpenClaw cannot resolve the Hive skill" ]
            return finish(expected, native.freeze, empty_resolution, issues)
          end

          list = JSON.parse(list_result.stdout)
          info = JSON.parse(info_result.stdout)
          validate_documents!(list, info)
          resolution = {
            "status" => "present",
            "path" => info.fetch("filePath"),
            "message" => "OpenClaw resolves /hive from #{info.fetch('filePath')}",
            "candidates" => [ info.fetch("filePath") ].freeze,
            "parse_errors" => [].freeze,
            "invocation" => "/hive",
            "source" => info["source"],
            "eligible" => info["eligible"],
            "user_invocable" => info["userInvocable"]
          }.freeze
          issues << [ "missing", "OpenClaw reports the Hive skill disabled or ineligible" ] unless info["eligible"] && info["userInvocable"]

          root, relative = trusted_install_root(list, info.fetch("baseDir"))
          relocated = CanonicalSkill::Projection.new(
            platform: @projection.platform,
            invocation: @projection.invocation,
            destination_relative: relative,
            skill_version: @projection.skill_version,
            canonical_digest: @projection.canonical_digest,
            files: @projection.files
          ).freeze
          report = DirectoryPublisher.new(
            root: root,
            trusted_root: @environment["HOME"] || Dir.home,
            projection: relocated
          ).report
          report_issues = trusted_clawhub_legacy?(report, info) ?
            [ [ "stale", "ClawHub Hive skill predates canonical provenance files" ] ] : report.issues
          issues.concat(report_issues)
          clawhub = info["clawhub"]
          if clawhub.nil? || clawhub["valid"] != true || clawhub["slug"] != "hive-cli"
            issues << [ "conflicting", "resolved OpenClaw Hive skill is not a valid hive-cli ClawHub installation" ]
          elsif clawhub["installedVersion"].to_s != @projection.skill_version
            issues << [ "stale", "ClawHub Hive skill #{clawhub['installedVersion']} does not match #{@projection.skill_version}" ]
          end
          native["clawhub"] = clawhub
          native["projection"] = {
            "state" => report.state,
            "destination" => report.destination,
            "manifest" => report.manifest,
            "files" => report.files,
            "snapshot" => report.snapshot
          }.freeze
          finish(expected, native.freeze, resolution, issues)
        rescue JSON::ParserError, KeyError, TypeError => e
          finish(
            expected,
            (native || { "available" => true, "bin" => bin, "commands" => commands || [] }).freeze,
            empty_resolution,
            [ [ "incompatible", "OpenClaw skill inventory is malformed: #{e.message}" ] ]
          )
        rescue DirectoryPublisher::Error => e
          finish(expected, native.freeze, empty_resolution, [ [ "conflicting", e.message ] ])
        end

        private

        def expected_hash
          {
            "distribution" => "clawhub",
            "package" => "hive-cli",
            "version" => @projection.skill_version,
            "canonical_digest" => @projection.canonical_digest,
            "source" => CLAWHUB_REF,
            "marketplace" => "ClawHub",
            "destination" => nil,
            "invocation" => @projection.invocation,
            "probe" => "SKILL.md",
            "files" => @projection.files.keys.sort.to_h do |path|
              [ path, ::Digest::SHA256.hexdigest(@projection.files.fetch(path)) ]
            end.freeze,
            "alias" => nil
          }.freeze
        end

        def finish(expected, native, resolution, issues)
          health, explanation = issues.min_by do |state, _|
            HEALTH_PRECEDENCE.index(state) || HEALTH_PRECEDENCE.length
          end || [ "healthy", "OpenClaw resolves the canonical Hive skill at #{resolution['path']}" ]
          remediation = if health == "missing"
            "openclaw skills install #{CLAWHUB_REF}"
          elsif health == "stale"
            "openclaw skills update #{CLAWHUB_REF}"
          elsif health == "healthy"
            "OpenClaw Hive skill is ClawHub-managed; no Hive setup write is required"
          else
            "inspect `openclaw skills info hive --json`; Hive will not modify OpenClaw or foreign skill content"
          end
          Evidence.new(
            expected: expected, native: native, resolution: resolution,
            health: health, explanation: explanation, remediation: remediation
          ).freeze
        end

        def validate_documents!(list, info)
          raise TypeError, "skill list must be an object" unless list.is_a?(Hash)
          raise TypeError, "skill info must be an object" unless info.is_a?(Hash)
          raise TypeError, "skill list rows must be an array" unless list["skills"].is_a?(Array)
          raise TypeError, "skill info name must be hive" unless info["name"] == "hive"
          %w[filePath baseDir].each { |key| raise KeyError, key unless info[key].is_a?(String) && !info[key].empty? }
        end

        def trusted_install_root(list, base_dir)
          base = File.expand_path(base_dir)
          candidates = [
            list["workspaceDir"] && File.join(list["workspaceDir"], "skills"),
            list["managedSkillsDir"]
          ].compact.map { |path| File.expand_path(path) }
          root = candidates.find { |candidate| base.start_with?(candidate + File::SEPARATOR) }
          raise DirectoryPublisher::UnsafePath, "OpenClaw Hive skill path is outside reported skill roots" unless root

          relative = base.delete_prefix(root).delete_prefix(File::SEPARATOR)
          [ root, relative ]
        end

        def trusted_clawhub_legacy?(report, info)
          return false unless report.state == "foreign" && report.manifest.nil?
          clawhub = info["clawhub"]
          skill_file = clawhub && clawhub["skillFile"]
          return false unless clawhub && clawhub["valid"] == true && skill_file.is_a?(Hash)
          path = info.fetch("filePath")
          return false unless File.file?(path) && !File.symlink?(path)

          ::Digest::SHA256.file(path).hexdigest == skill_file["sha256"]
        rescue SystemCallError
          false
        end

        def resolved_binary
          candidate = @environment["OPENCLAW_BIN"].to_s
          candidate = "openclaw" if candidate.empty?
          if candidate.include?(File::SEPARATOR)
            path = File.expand_path(candidate)
            return path if File.file?(path) && File.executable?(path)
            return nil
          end
          @environment.fetch("PATH", ENV.fetch("PATH", "")).split(File::PATH_SEPARATOR).each do |directory|
            path = File.join(directory, candidate)
            return path if File.file?(path) && File.executable?(path)
          end
          nil
        end

        def run(argv, commands)
          commands << argv.freeze
          @runner.call(argv, env: runner_environment, timeout: TIMEOUT_SEC)
        end

        def runner_environment
          %w[HOME PATH OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH].each_with_object({}) do |key, out|
            out[key] = @environment[key] if @environment.key?(key)
          end
        end

        def parse_version(output)
          output.to_s[/\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.-]+)?/]
        end

        def command_failure(result)
          return "timed out" if result.timed_out
          return result.error unless result.error.to_s.empty?
          detail = result.stderr.to_s.lines.first.to_s.strip
          detail.empty? ? "command failed" : detail
        end

        def empty_resolution
          { "status" => "unavailable", "path" => nil, "message" => nil,
            "candidates" => [], "parse_errors" => [], "invocation" => "/hive" }.freeze
        end
      end
    end
  end
end
