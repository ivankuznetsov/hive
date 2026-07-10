module Hive
  # Canonical, versioned rules for publish-time behaviors that require an
  # explicit shell capability declaration and registry review.
  module DenyPatterns
    RULE_SET_VERSION = 1

    Rule = Data.define(
      :id,
      :severity,
      :capability,
      :description,
      :remediation,
      :regex
    )
    Finding = Data.define(:rule_id, :file, :line, :severity, :capability, :remediation)

    RULES = [
      Rule.new(
        id: :shell_download_to_interpreter,
        severity: "high",
        capability: "Bash",
        description: "Downloads remote content and pipes it directly to an interpreter.",
        remediation: "Download to a pinned file, verify its digest, and execute it only in an explicitly justified Bash context.",
        regex: /(?:\bcurl\b|\bwget\b)[^|\n]*\|\s*(?:sh|bash|zsh|fish|python\d?|ruby|node|perl)\b/i
      ).freeze,
      Rule.new(
        id: :credential_path_access,
        severity: "high",
        capability: "Bash",
        description: "Reads from a local credential directory.",
        remediation: "Remove direct credential-file access and use the runtime's secret or authenticated tool integration.",
        regex: /\b(?:cat|less|more|head|tail|sed|awk|cp|scp|rsync|find|ls)\b[^\n]*(?:~|\$HOME|\$\{HOME\})\/(?:\.ssh|\.aws|\.config\/(?:gh|gcloud))(?:\/|\b)/i
      ).freeze,
      Rule.new(
        id: :outbound_data_transfer,
        severity: "high",
        capability: "Bash",
        description: "Uploads a local file or standard input to a network endpoint.",
        remediation: "Remove the upload or use a declared, reviewable integration that constrains the destination and data.",
        regex: /\bcurl\b[^\n]*(?:--data(?:-binary|-raw)?\s+@(?:-|[^\s]+)|--upload-file\s+[^\s]+|-T\s+[^\s]+)/i
      ).freeze
    ].freeze

    module_function

    def rules
      RULES
    end

    def rule(id)
      RULES.find { |candidate| candidate.id == id.to_sym } ||
        raise(KeyError, "unknown deny rule: #{id}")
    end

    def scan(text, file:)
      normalized = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
      return [] if normalized.empty?

      RULES.flat_map do |descriptor|
        normalized.to_enum(:scan, descriptor.regex).map do
          match = Regexp.last_match
          Finding.new(
            rule_id: descriptor.id.to_s,
            file: file.to_s,
            line: normalized[0...match.begin(0)].count("\n") + 1,
            severity: descriptor.severity,
            capability: descriptor.capability,
            remediation: descriptor.remediation
          ).freeze
        end
      end.sort_by { |finding| [ finding.file, finding.line, finding.rule_id ] }.freeze
    end
  end
end
