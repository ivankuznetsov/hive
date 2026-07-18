require "uri"
require "hive/secret_patterns"
require "hive/workflow_package/diagnostic"

module Hive
  module WorkflowPackage
    module SecurityScanner
      NETWORK_RE = %r{\b(?:curl|wget|WebFetch|https?://|upload|download|fetch)\b}i
      CREDENTIAL_RE = /\b(?:credential|token|password|secret|api[_-]?key|\.env|keychain)\b/i
      SHELL_RE = /(?:^|\s)(?:bash|sh|zsh|python|ruby|node|git|gh|curl|wget)(?:\s|$)/i
      EXFILTRATION_RE = /\b(?:upload|post|send|exfiltrat|transmit)\b.{0,120}\b(?:secret|token|credential|password|\.env)\b/i
      SECRET_ORDER = %i[anthropic_api_key openai_api_key].freeze

      module_function

      def scan_files(root, paths:, permissions: {})
        paths.flat_map do |relative|
          next [] unless relative.end_with?(".md", ".yml", ".yaml", ".json")
          next [] unless File.file?(File.join(root, relative))

          scan_text(File.read(File.join(root, relative)), path: relative, permissions: permissions)
        end
      end

      def scan_text(text, path:, permissions: {})
        findings = secret_findings(text, path)
        findings << behavior_diagnostic("security.exfiltration", text, path, EXFILTRATION_RE,
                                        :error, "unequivocal credential exfiltration behavior is not permitted") if EXFILTRATION_RE.match?(text)

        domains = Array(fetch_permission(permissions, "domains"))
        if NETWORK_RE.match?(text)
          declared = domains.any? && referenced_domains(text).all? { |domain| domain_allowed?(domain, domains) }
          rule = declared ? "security.declared_network" : "security.undeclared_network"
          severity = declared ? :warning : :error
          message = declared ? "declared network behavior requires human review" : "network behavior must be declared with allowed domains"
          findings << behavior_diagnostic(rule, text, path, NETWORK_RE, severity, message)
        end

        credentials = Array(fetch_permission(permissions, "credentials"))
        if CREDENTIAL_RE.match?(text) && findings.none? { |finding| finding.rule_id.start_with?("security.") && finding.rule_id.end_with?("_token", "_key", "_assignment", "_cookie", "jwt") }
          declared = credentials.any?
          findings << behavior_diagnostic(
            declared ? "security.declared_credentials" : "security.undeclared_credentials",
            text, path, CREDENTIAL_RE, declared ? :warning : :error,
            declared ? "declared credential behavior requires human review" : "credential access must be declared"
          )
        end

        commands = Array(fetch_permission(permissions, "commands"))
        # honeycomb.yml is the declaration document itself: a deny entry such
        # as `- Bash` is policy data, not an instruction to run a shell.
        if SHELL_RE.match?(text) && commands.empty? && File.basename(path) != "honeycomb.yml"
          findings << behavior_diagnostic("security.undeclared_shell", text, path, SHELL_RE, :error,
                                          "shell behavior must be declared with exact commands")
        end
        findings.compact.uniq { |finding| [ finding.rule_id, finding.path, finding.line, finding.column ] }
      end

      def secret_findings(text, path)
        ordered = SECRET_ORDER.filter_map do |name|
          pattern = Hive::SecretPatterns::PATTERNS[name]
          [ name, pattern ] if pattern
        end
        ordered.concat(Hive::SecretPatterns::PATTERNS.reject { |name, _| SECRET_ORDER.include?(name) }.to_a)
        occupied = []
        ordered.flat_map do |name, pattern|
          text.to_enum(:scan, pattern).filter_map do
            match = Regexp.last_match
            range = match.begin(0)...match.end(0)
            next if occupied.any? { |existing| existing.cover?(range.begin) || range.cover?(existing.begin) }

            occupied << range
            line, column = location(text, match.begin(0))
            Diagnostic.new(
              rule_id: "security.#{name}", severity: :error, path: path,
              line: line, column: column, message: "possible secret material is not permitted in workflow packages"
            )
          end
        end
      end

      def behavior_diagnostic(rule, text, path, pattern, severity, message)
        match = pattern.match(text)
        line, column = location(text, match.begin(0))
        Diagnostic.new(rule_id: rule, severity: severity, path: path, line: line, column: column, message: message)
      end

      def location(text, offset)
        before = text.byteslice(0, offset).to_s
        [ before.count("\n") + 1, before.byteslice((before.rindex("\n") || -1) + 1..)&.length.to_i + 1 ]
      end

      def referenced_domains(text)
        text.scan(%r{https?://([^/\s"')]+)}i).flatten.map { |value| value.downcase.sub(/:\d+\z/, "") }.uniq
      end

      def domain_allowed?(domain, allowed)
        allowed.any? do |entry|
          normalized = entry.to_s.downcase.sub(/\A\*\./, "")
          domain == normalized || (entry.to_s.start_with?("*.") && domain.end_with?(".#{normalized}"))
        end
      end

      def fetch_permission(permissions, key)
        permissions[key] || permissions[key.to_sym]
      end
    end
  end
end
