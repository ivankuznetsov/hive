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
        CLAWHUB_REF = "@ivankuznetsov/hive-cli"
        CLAWHUB_METADATA_FILES = [ ".clawhub/origin.json", "_meta.json" ].freeze
        MISSING_DOCUMENT = Object.new.freeze
        HEALTH_PRECEDENCE = %w[conflicting incompatible unavailable stale missing healthy].freeze
        Evidence = Data.define(:expected, :native, :resolution, :health, :explanation, :remediation)

        def initialize(environment: ENV)
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

          inspect_filesystem(expected, bin)
        end

        private

        def inspect_filesystem(expected, bin)
          commands = [].freeze
          native = {
            "available" => true,
            "bin" => bin,
            "cli_version" => nil,
            "commands" => commands,
            "inventory_source" => "filesystem",
            "clawhub" => nil,
            "projection" => nil
          }
          workspace = configured_workspace
          candidates = filesystem_skill_roots(workspace)
          if candidates.empty?
            return finish(expected, native.freeze, empty_resolution,
                          [ [ "missing", "OpenClaw cannot resolve the Hive skill from its workspace" ] ])
          end

          issues = []
          if candidates.length > 1
            issues << [ "conflicting", "multiple OpenClaw Hive skill directories are present: #{candidates.join(', ')}" ]
          end
          base = candidates.first
          skill_path = File.join(base, "SKILL.md")
          root = File.dirname(base)
          report = projection_report(
            root: root,
            relative: File.basename(base),
            allowed_extra_files: CLAWHUB_METADATA_FILES
          )
          clawhub = filesystem_clawhub(
            workspace, base, report.files.dig("SKILL.md", "digest")
          )
          workspace_skill_root = File.join(workspace, "skills") + File::SEPARATOR
          source = base.start_with?(workspace_skill_root) ? "openclaw-workspace" : "openclaw-managed"
          resolution = {
            "status" => "present",
            "path" => skill_path,
            "message" => "OpenClaw resolves #{@projection.invocation} from #{skill_path}",
            "candidates" => candidates.map { |path| File.join(path, "SKILL.md") }.freeze,
            "parse_errors" => [].freeze,
            "invocation" => @projection.invocation,
            "source" => source,
            "eligible" => nil,
            "user_invocable" => nil
          }.freeze
          finish_projection(
            expected: expected, native: native, resolution: resolution,
            issues: issues, report: report, clawhub: clawhub
          )
        rescue JSON::ParserError, KeyError, TypeError => e
          finish(
            expected,
            (native || { "available" => true, "bin" => bin, "commands" => [] }).freeze,
            empty_resolution,
            [ [ "incompatible", "OpenClaw filesystem inventory is malformed: #{e.message}" ] ]
          )
        rescue DirectoryPublisher::Error, SystemCallError => e
          finish(expected, native.freeze, empty_resolution, [ [ "conflicting", e.message ] ])
        end

        def configured_workspace
          state = openclaw_state_dir
          config_path = @environment["OPENCLAW_CONFIG_PATH"].to_s
          config_path = File.join(state, "openclaw.json") if config_path.empty?
          config = read_json_if_file(config_path)
          config = {} if config.equal?(MISSING_DOCUMENT)
          raise TypeError, "#{config_path} must contain an object" unless config.is_a?(Hash)

          configured = config.dig("agents", "defaults", "workspace")
          configured = File.join(state, "workspace") unless configured.is_a?(String) && !configured.empty?
          File.expand_path(configured, state)
        end

        def filesystem_skill_roots(workspace)
          roots = [ File.join(workspace, "skills"), File.join(openclaw_state_dir, "skills") ].uniq
          roots.product(%w[hive-cli hive]).map { |root, name| File.join(root, name) }
            .select { |path| File.file?(File.join(path, "SKILL.md")) }
            .sort.freeze
        end

        def filesystem_clawhub(workspace, base, skill_digest)
          origin_path = File.join(base, ".clawhub", "origin.json")
          origin = read_json_if_file(origin_path)
          return nil if origin.equal?(MISSING_DOCUMENT)
          raise TypeError, "#{origin_path} must contain an object" unless origin.is_a?(Hash)
          lock_paths = [ workspace, openclaw_state_dir ].uniq.map do |root|
            File.join(root, ".clawhub", "lock.json")
          end
          lock = nil
          lock_path = lock_paths.find do |path|
            lock = read_json_if_file(path)
            !lock.equal?(MISSING_DOCUMENT)
          end
          lock = nil if lock.equal?(MISSING_DOCUMENT)
          raise TypeError, "#{lock_path} must contain an object" if lock && !lock.is_a?(Hash)
          lock_entry = lock&.dig("skills", File.basename(base)) || lock&.dig("skills", "hive-cli")
          skill_file = origin["skillFile"]
          valid = origin["version"] == 1 && origin["slug"] == "hive-cli" &&
            skill_file.is_a?(Hash) && skill_file["path"] == "SKILL.md" &&
            skill_file["sha256"] == skill_digest && lock_entry.is_a?(Hash) &&
            (lock_entry["version"] || lock_entry["installedVersion"]) == origin["installedVersion"] &&
            lock_entry.dig("skillFile", "sha256") == skill_digest
          {
            "status" => "linked",
            "valid" => valid,
            "slug" => origin["slug"],
            "installedVersion" => origin["installedVersion"],
            "registry" => origin["registry"],
            "skillFile" => skill_file
          }.freeze
        end

        def read_json_if_file(path)
          JSON.parse(File.binread(path))
        rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EISDIR
          MISSING_DOCUMENT
        end

        def projection_report(root:, relative:, allowed_extra_files: [])
          relocated = @projection.with(destination_relative: relative)
          DirectoryPublisher.new(
            root: root,
            trusted_root: @environment["HOME"] || Dir.home,
            projection: relocated
          ).report(allowed_extra_files: allowed_extra_files)
        end

        def finish_projection(expected:, native:, resolution:, issues:, report:, clawhub:)
          report_issues = trusted_clawhub_legacy?(report, clawhub) ?
            [ [ "stale", "ClawHub Hive skill predates canonical provenance files" ] ] : report.issues
          issues.concat(report_issues)
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
        end

        def openclaw_state_dir
          state = @environment["OPENCLAW_STATE_DIR"].to_s
          state = File.join(@environment["HOME"] || Dir.home, ".openclaw") if state.empty?
          File.expand_path(state)
        end

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

        def trusted_clawhub_legacy?(report, clawhub)
          return false unless report.state == "foreign" && report.manifest.nil?
          skill_file = clawhub && clawhub["skillFile"]
          return false unless clawhub && clawhub["valid"] == true && skill_file.is_a?(Hash)

          report.files.dig("SKILL.md", "digest") == skill_file["sha256"]
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

        def empty_resolution
          { "status" => "unavailable", "path" => nil, "message" => nil,
            "candidates" => [], "parse_errors" => [], "invocation" => @projection.invocation }.freeze
        end
      end
    end
  end
end
