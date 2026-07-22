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
      DIRECT_PROHIBITION_RE = /\b(?:do\s+not|don't|does\s+not|must\s+not|should\s+not|may\s+not|cannot|can't|never)\b/i
      DENIAL_VERB_RE = /\b(?:forbid(?:s|den)?|prohibit(?:s|ed)?|disallow(?:s|ed)?|den(?:y|ies|ied))\b/i
      ABSENCE_RE = /\bno\s+(?:[a-z][\w-]*\s+){0,5}
                    (?:has|have|uses?|allows?|requires?|access(?:es)?|receives?|reads?|writes?|runs?|fetches?|uploads?)\b/ix
      NON_GOVERNING_NEGATION_RE = /\b(?:forget|hesitate|fail|skip|refuse|neglect|avoid|omit|stop|not)\b|
                                    \bwithout\s+exception\b/ix
      DANGEROUS_ACTION = "(?:upload|post|send|exfiltrat\\w*|transmit|download|fetch|curl|wget|" \
                         "run|execute|invoke|call|use|read|access|retrieve|load|expose|write|" \
                         "include|provide|share|store|print|log|connect|request)".freeze
      MIXED_CLAUSE_RE = /;|\b(?:but|however|instead)\b|,\s*(?:then\s+)?#{DANGEROUS_ACTION}\b/i
      DIRECT_ACTION_GAP_RE = /\A\s*(?:then\s+)?#{DANGEROUS_ACTION}\b(?:[\s,]+[a-z0-9_.\/-]+){0,6}[\s,]*\z/i
      POSTFIX_PROHIBITION_RE = /\A(?:\s+[a-z0-9_.\/-]+){0,4}\s+(?:is|are)\s+(?:strictly\s+)?
                                (?:forbidden|prohibited|disallowed|denied|not\s+(?:permitted|allowed))\b/ix
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
        exfiltration = affirmative_match(text, EXFILTRATION_RE)
        if exfiltration
          findings << behavior_diagnostic("security.exfiltration", text, path, exfiltration,
                                          :error, "unequivocal credential exfiltration behavior is not permitted")
        end

        domains = Array(fetch_permission(permissions, "domains") || fetch_permission(permissions, "network_hosts"))
        network = affirmative_match(text, NETWORK_RE)
        if network
          declared = domains.any? && referenced_domains(text).all? { |domain| domain_allowed?(domain, domains) }
          rule = declared ? "security.declared_network" : "security.undeclared_network"
          severity = declared ? :warning : :error
          message = declared ? "declared network behavior requires human review" : "network behavior must be declared with allowed domains"
          findings << behavior_diagnostic(rule, text, path, network, severity, message)
        end

        credentials = Array(fetch_permission(permissions, "credentials") || fetch_permission(permissions, "secrets"))
        credential = affirmative_match(text, CREDENTIAL_RE)
        if credential && findings.none? { |finding| finding.rule_id.start_with?("security.") && finding.rule_id.end_with?("_token", "_key", "_assignment", "_cookie", "jwt") }
          declared = credentials.any?
          findings << behavior_diagnostic(
            declared ? "security.declared_credentials" : "security.undeclared_credentials",
            text, path, credential, declared ? :warning : :error,
            declared ? "declared credential behavior requires human review" : "credential access must be declared"
          )
        end

        commands = Array(fetch_permission(permissions, "commands"))
        capabilities = Array(fetch_permission(permissions, "capabilities"))
        shell_declared = commands.any? || capabilities.include?("shell")
        # honeycomb.yml is the declaration document itself: a deny entry such
        # as `- Bash` is policy data, not an instruction to run a shell.
        shell = affirmative_match(text, SHELL_RE)
        if shell && !shell_declared && File.basename(path) != "honeycomb.yml"
          findings << behavior_diagnostic("security.undeclared_shell", text, path, shell, :error,
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

      def behavior_diagnostic(rule, text, path, match, severity, message)
        line, column = location(text, match.begin(0))
        Diagnostic.new(rule_id: rule, severity: severity, path: path, line: line, column: column, message: message)
      end

      def affirmative_match(text, pattern)
        each_match(text, pattern) do |match|
          return match unless prohibited_match?(text, match)
        end
        nil
      end

      # Advance from the prior match's start, not its end, so an early
      # prohibited phrase cannot consume and hide a later affirmative match.
      def each_match(text, pattern)
        offset = 0
        while (match = pattern.match(text, offset))
          yield match
          offset = match.begin(0) + 1
        end
      end

      def prohibited_match?(text, match)
        line_end = text.index("\n", match.end(0)) || text.length
        prefix = text[0...match.begin(0)]
        boundary = [ prefix.rindex(/[.!?]\s+/), prefix.rindex(/\n\s*\n/) ].compact.max
        statement_start = boundary ? boundary + 1 : 0
        statement = text[statement_start...line_end]
        relative_start = match.begin(0) - statement_start
        relative_end = match.end(0) - statement_start
        before = statement[0...relative_start]
        after = statement[relative_end..]
        at_match = statement[relative_start..]

        # A comma immediately before a new dangerous action starts a fresh
        # clause; the action itself is outside the prefix inspected below.
        return false if /,\s*(?:then\s+)?\z/i.match?(before) && /\A\s*#{DANGEROUS_ACTION}\b/i.match?(at_match)

        direct_prefix_prohibition?(before) ||
          direct_no_prohibition?(before) ||
          direct_absence?(before) ||
          direct_without_prohibition?(before) ||
          direct_denial_verb?(before) ||
          POSTFIX_PROHIBITION_RE.match?(after.to_s)
      end

      def direct_prefix_prohibition?(before)
        marker = last_match(before, DIRECT_PROHIBITION_RE)
        return false unless marker

        governed = before[marker.end(0)..]
        directly_governs_match?(governed)
      end

      def direct_absence?(before)
        marker = last_match(before, ABSENCE_RE)
        return false unless marker

        governed = before[marker.end(0)..]
        !NON_GOVERNING_NEGATION_RE.match?(governed) && !MIXED_CLAUSE_RE.match?(governed)
      end

      def direct_no_prohibition?(before)
        marker = last_match(before, /\bno\b/i)
        return false unless marker

        directly_governs_match?(before[marker.end(0)..])
      end

      def direct_without_prohibition?(before)
        marker = last_match(before, /\bwithout\b/i)
        return false unless marker

        governed = before[marker.end(0)..]
        return false if governed.lstrip.start_with?("exception")

        directly_governs_match?(governed)
      end

      def direct_denial_verb?(before)
        marker = last_match(before, DENIAL_VERB_RE)
        return false unless marker

        marker_prefix = before[0...marker.begin(0)]
        return false if /\b(?:not|never|cannot|can't)\s*\z/i.match?(marker_prefix)

        directly_governs_match?(before[marker.end(0)..])
      end

      def directly_governs_match?(governed)
        return false if NON_GOVERNING_NEGATION_RE.match?(governed)
        return false if MIXED_CLAUSE_RE.match?(governed)

        final_conjunct = governed.split(/\b(?:and|or)\b/i).last.to_s
        final_conjunct.strip.empty? || DIRECT_ACTION_GAP_RE.match?(final_conjunct)
      end

      def last_match(text, pattern)
        last = nil
        text.to_enum(:scan, pattern).each { last = Regexp.last_match }
        last
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
          next true if entry.to_s == "*"

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
