require "rubygems/version"
require "hive/agent_profiles"
require "hive/deny_patterns"
require "hive/honeycomb"
require "hive/honeycomb/manifest"
require "hive/secret_patterns"

module Hive
  module Honeycomb
    module Preflight
      Finding = Data.define(:kind, :rule, :file, :line, :message, :remediation, :contexts)
      Result = Data.define(:status, :package, :findings, :dependencies, :review_required) do
        def success?
          status != :blocked
        end

        def clean?
          status == :clean
        end
      end

      module_function

      def run(package:, project_root:, cfg: {}, hive_version: Hive::VERSION)
        findings = []
        findings.concat(compatibility_findings(package, hive_version))
        findings.concat(dependency_findings(package, project_root, cfg || {}))
        security, review_required = security_findings(package)
        findings.concat(security)
        findings = sort_findings(findings).freeze
        review_required = sort_review_required(review_required).freeze

        return Result.new(
          status: :blocked,
          package: package,
          findings: findings,
          dependencies: package.dependencies,
          review_required: review_required
        ) unless findings.empty?

        manifest = Manifest.write(
          package_root: package.package_root,
          id: package.id,
          metadata: package.metadata,
          dependencies: package.dependencies,
          permission_summary: package.permission_summary,
          review_required: review_required
        )
        finalized = package.with_manifest(manifest)
        Result.new(
          status: review_required.empty? ? :clean : :review_required,
          package: finalized,
          findings: findings,
          dependencies: package.dependencies,
          review_required: review_required
        )
      end

      def compatibility_findings(package, hive_version)
        minimum = package.metadata.fetch("minimum_hive_version")
        return [] if comparable_version(hive_version) >= comparable_version(minimum)

        [ Finding.new(
          kind: "compatibility",
          rule: "minimum_hive_version",
          file: "workflow.yml",
          line: nil,
          message: "workflow requires Hive #{minimum}, but this Hive is #{hive_version}",
          remediation: "upgrade Hive to #{minimum} or newer before publishing",
          contexts: [].freeze
        ).freeze ]
      end

      def comparable_version(value)
        Gem::Version.new(value.to_s.split("+", 2).first)
      end

      def dependency_findings(package, project_root, cfg)
        package.dependencies.filter_map do |dependency|
          verify_dependency(dependency, project_root, cfg)
        end
      end

      def verify_dependency(dependency, project_root, cfg)
        profile = Hive::AgentProfiles.lookup(dependency.fetch("agent"), cfg: cfg)
        invocation = profile.format_skill_invocation(dependency.fetch("skill"))
        status, detail = profile.verify_skill(invocation, project_root: project_root)
        return nil if status == :present

        rule = status == :not_applicable ? "skill_not_applicable" : "skill_missing"
        dependency_finding(dependency, rule, detail.to_s)
      rescue Hive::AgentProfiles::UnknownAgent => e
        dependency_finding(dependency, "unknown_agent", e.message)
      rescue StandardError => e
        dependency_finding(
          dependency,
          "skill_verification_failed",
          "#{e.class.name.split('::').last}: verifier could not check this dependency"
        )
      end

      def dependency_finding(dependency, rule, detail)
        # A skill identifier or verifier detail can itself be token-shaped and
        # trip a secret pattern; redact both before they reach the JSON/human
        # output so a diagnostic never echoes credential material verbatim.
        skill = Hive::SecretPatterns.redact(dependency.fetch("skill").to_s)
        Finding.new(
          kind: "dependency",
          rule: rule,
          file: "workflow.yml",
          line: nil,
          message: "required skill #{skill.inspect} for " \
                   "#{dependency.fetch('context')} (#{dependency.fetch('agent')}) is not verifiable",
          remediation: Hive::SecretPatterns.redact(detail.to_s),
          contexts: [ dependency.fetch("context") ].freeze
        ).freeze
      end

      def security_findings(package)
        blocked = []
        review_required = []
        permission_contexts = package.permission_summary.fetch("contexts").to_h do |row|
          [ row.fetch("context"), row ]
        end

        package.files.reject { |path| path == Hive::Honeycomb::MANIFEST_FILENAME }.sort.each do |relative|
          bytes = read_for_scan(package, relative)
          Hive::SecretPatterns.safe_scan(bytes, file: relative).each do |finding|
            blocked << Finding.new(
              kind: "secret",
              rule: finding.rule_id,
              file: finding.file,
              line: finding.line,
              message: "secret material detected by #{finding.rule_id}",
              remediation: finding.remediation,
              contexts: Array(package.owners[relative]).freeze
            ).freeze
          end
          Hive::DenyPatterns.scan(bytes, file: relative).each do |finding|
            owners = Array(package.owners[relative]).sort.freeze
            if justified?(owners, permission_contexts)
              review_required << review_record(finding, owners, permission_contexts)
            else
              blocked << Finding.new(
                kind: "deny",
                rule: finding.rule_id,
                file: finding.file,
                line: finding.line,
                message: "high-risk shell behavior requires explicit justified Bash in every owning context",
                remediation: finding.remediation,
                contexts: owners
              ).freeze
            end
          end
        end
        [ blocked, review_required ]
      end

      # Reads a packaged file for the secret/deny scan, re-raising any read
      # failure with scan context so a partially completed scan can never be
      # mistaken for a clean one. The wrapped error keeps its original class so
      # the CLI's SystemCallError/IOError handling still applies.
      def read_for_scan(package, relative)
        File.binread(File.join(package.package_root, relative))
      rescue SystemCallError, IOError => e
        raise e.class, "could not read #{relative} during secret/deny scan: #{e.message}"
      end

      def justified?(owners, permission_contexts)
        !owners.empty? && owners.all? do |context|
          row = permission_contexts[context]
          row && row.fetch("shell_exposure") == "explicit_bash" &&
            !row["shell_justification"].to_s.strip.empty?
        end
      end

      def review_record(finding, owners, permission_contexts)
        justifications = owners.map do |context|
          "#{context}: #{permission_contexts.fetch(context).fetch('shell_justification')}"
        end
        {
          "rule" => finding.rule_id,
          "file" => finding.file,
          "line" => finding.line,
          "contexts" => owners,
          "justification" => justifications.join("; ")
        }.freeze
      end

      def sort_findings(findings)
        findings.sort_by do |finding|
          [ finding.file.to_s, finding.line.to_i, finding.kind, finding.rule ]
        end
      end

      def sort_review_required(records)
        Hive::Honeycomb.sort_review_required(records)
      end
    end
  end
end
