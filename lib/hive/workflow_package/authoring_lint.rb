require "digest"
require "find"
require "uri"
require "hive/workflow_package/lint_policy"

module Hive
  module WorkflowPackage
    class AuthoringLint
      class LintError < Hive::ConfigError
        attr_reader :result

        def initialize(result)
          @result = result
          super("Honeycomb authoring lint failed: #{result.errors.first&.message || 'unknown lint failure'}")
        end
      end

      Finding = Data.define(
        :rule_id, :severity, :path, :line, :column, :message,
        :review_required, :suppression_allowed
      ) do
        def error? = severity == :error
        def warning? = severity == :warning

        def to_h
          {
            "rule_id" => rule_id, "severity" => severity.to_s, "path" => path,
            "line" => line, "column" => column, "message" => message,
            "review_required" => review_required,
            "suppression_allowed" => suppression_allowed
          }.compact.freeze
        end
      end

      Result = Data.define(:contract, :findings) do
        def errors = findings.select(&:error?)
        def warnings = findings.select(&:warning?)
        def valid? = errors.empty?
      end

      SECRET_PATTERNS = [
        [ "secret.private-key", /-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----/, "Private key material detected" ],
        [ "secret.github-token", /\bgh[pousr]_[A-Za-z0-9]{20,}\b/, "GitHub credential detected" ],
        [ "secret.openai-key", /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/, "OpenAI credential detected" ],
        [ "secret.anthropic-key", /\bsk-ant-[A-Za-z0-9_-]{20,}\b/, "Anthropic credential detected" ],
        [ "secret.aws-access-key", /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/, "AWS access key detected" ],
        [ "secret.slack-token", /\bxox[baprs]-[0-9A-Za-z-]{10,}\b/, "Slack credential detected" ],
        [ "secret.google-api-key", /\bAIza[0-9A-Za-z_-]{30,}\b/, "Google API credential detected" ],
        [ "secret.jwt", /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/, "JWT-shaped credential detected" ],
        [ "secret.bearer", /\bBearer\s+[A-Za-z0-9._~+\/-]{20,}={0,2}\b/i, "Bearer credential detected" ],
        [ "secret.generic-assignment", /\b(?:api[_-]?key|client[_-]?secret|password|token)\b\s*[:=]\s*["']([^"'\s]{16,})["']/i, "High-entropy credential assignment detected" ]
      ].freeze
      PII_PATTERNS = [
        [ "pii.government-id", /\b(?:ssn|social\s+security(?:\s+number)?|national\s+id)\s*[:#-]?\s*\d{3}-\d{2}-\d{4}\b/i, :error, "Context-labeled government identifier detected" ],
        [ "pii.email", /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i, :warning, "Email address observed" ],
        [ "pii.phone", /(?<![A-Z0-9])(?:\+?\d[\s().-]*){10,15}(?![A-Z0-9])/i, :warning, "Phone-like personal data observed" ]
      ].freeze
      DENY_RULES = [
        [ "deny.pipe-to-shell", /\b(?:curl|wget)\b[^\n|]*\|\s*["']?(?:sudo\s+)?(?:ba|z)?sh(?:["']|\s|\z)/i, "Network response is piped to a shell" ],
        [ "deny.credential-read", %r{(?:~|\$\{?HOME\}?)/(?:\.ssh|\.aws|\.config/gh|\.kube/config|\.npmrc|\.netrc|\.git-credentials|\.docker/config\.json)|/\.aws/credentials}i, "Command reads a credential-bearing path" ],
        [ "deny.environment-dump", /\A\s*(?:(?:env|printenv)(?:\z|(?!\s*(?:=|<<))\s+)|set\s*\z)/i, "Command dumps environment values" ],
        [ "deny.path-traversal", %r{(?:\A|[\s"'])\.\./}, "Command contains parent traversal" ],
        [ "deny.encoded-exfiltration", /\b(?:base64|openssl\s+enc|gzip|tar|zip)\b[^\n|;]*(?:\||;|&&)[^\n]*(?:curl|wget)\b/i, "Encoded or compressed data is sent to a network client" ]
      ].freeze
      COMMAND_RE = /\b(?:bash|sh|zsh|ruby|python|node|git|gh|curl|wget|chmod|env|printenv)\b/i
      URL_RE = %r{https?://[^\s"'<>`)]+}i

      def self.verify(root, manifest:, policy: nil)
        new(root, manifest: manifest, policy: policy || LintPolicy.load).verify
      rescue StandardError => e
        raise if e.is_a?(Hive::ConfigError)

        finding = Finding.new(
          rule_id: "policy.scanner-error", severity: :error, path: "manifest.yml",
          line: nil, column: nil, message: "local Honeycomb scanner failed closed",
          review_required: false, suppression_allowed: false
        )
        Result.new(contract: {}, findings: [ finding ].freeze).freeze
      end

      def self.verify!(...)
        result = verify(...)
        raise LintError, result unless result.valid?
        result
      end

      def initialize(root, manifest:, policy:)
        @root = File.expand_path(root)
        @manifest = manifest
        @policy = policy
        @findings = []
      end

      def verify
        files = collect_files
        files.each { |entry| scan_entry(entry) }
        validate_rules!
        findings = @findings.uniq { |item| [ item.rule_id, item.path, item.line, item.column ] }
                            .sort_by { |item| [ item.path, item.line || 0, item.column || 0, item.rule_id ] }
        Result.new(contract: @policy.identity, findings: findings.freeze).freeze
      end

      private

      def collect_files
        entries = []
        total = 0
        Find.find(@root) do |path|
          next if path == @root
          relative = path.delete_prefix("#{@root}/")
          stat = File.lstat(path)
          if stat.symlink? || (!stat.directory? && !stat.file?)
            add("policy.invalid-file", :error, relative, nil, nil, "package contains a linked or special file")
            Find.prune if stat.directory?
            next
          end
          next if stat.directory?
          next if relative == "manifest.yml"
          if entries.length >= @policy.limits.fetch("max_files")
            add("policy.file-limit", :error, relative, nil, nil, "package file count exceeds lint policy")
            break
          end
          if stat.size > @policy.limits.fetch("max_file_bytes")
            add("policy.file-limit", :error, relative, nil, nil, "package file exceeds lint byte limit")
            next
          end
          total += stat.size
          if total > @policy.limits.fetch("max_total_bytes")
            add("policy.total-limit", :error, relative, nil, nil, "package total bytes exceed lint policy")
            break
          end
          entries << [ relative, File.binread(path) ]
        end
        entries
      rescue SystemCallError, IOError
        add("policy.invalid-file", :error, "", nil, nil, "package files could not be read safely")
        []
      end

      def scan_entry(entry)
        path, bytes = entry
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding?
          add("policy.invalid-encoding", :error, path, nil, nil, "text input is not valid UTF-8")
          return
        end
        if text.include?("\0")
          add("review.binary-file", :warning, path, nil, nil, "binary package file requires registry review", review: true)
          return
        end

        scan_patterns(text, path)
        commands = extract_commands(text, path)
        scan_commands(commands)
        scan_network(text, path)
      end

      def scan_patterns(text, path)
        text.each_line.with_index(1) do |line, line_number|
          SECRET_PATTERNS.each do |rule, regex, message|
            each_match(line, regex) { |match| add(rule, :error, path, line_number, match.begin(0) + 1, message) }
          end
          PII_PATTERNS.each do |rule, regex, severity, message|
            each_match(line, regex) do |match|
              next if rule == "pii.phone" && !match[0].scan(/\d/).length.between?(10, 15)
              add(rule, severity, path, line_number, match.begin(0) + 1, message, review: severity == :warning)
            end
          end
        end
      end

      def extract_commands(text, path)
        commands = []
        fenced = false
        text.each_line.with_index(1) do |line, line_number|
          if line.match?(/^\s*```/)
            fenced = !fenced
            next
          end
          candidates = line.scan(/`([^`]+)`/).flatten
          candidates << line.strip if fenced || line.match?(COMMAND_RE) || DENY_RULES.any? { |_rule, regex, _message| line.match?(regex) }
          candidates.reject(&:empty?).uniq.each do |raw|
            commands << { path: path, line: line_number, column: [ line.index(raw).to_i + 1, 1 ].max, raw: raw }
          end
        end
        commands
      end

      def scan_commands(commands)
        commands.each do |command|
          DENY_RULES.each do |rule, regex, message|
            match = regex.match(command.fetch(:raw))
            add(rule, :error, command.fetch(:path), command.fetch(:line), command.fetch(:column) + match.begin(0), message) if match
          end
          next unless command.fetch(:raw).match?(COMMAND_RE)
          declared = Array(@manifest.permissions["capabilities"]).include?("shell")
          add(
            "review.command", declared ? :warning : :error, command.fetch(:path),
            command.fetch(:line), command.fetch(:column),
            declared ? "declared command requires registry review" : "command behavior is not declared by package permissions",
            review: true
          )
        end
      end

      def scan_network(text, path)
        text.each_line.with_index(1) do |line, line_number|
          line.to_enum(:scan, URL_RE).each do
            match = Regexp.last_match
            host = URI.parse(match[0]).host.to_s.downcase
            declared = host_allowed?(host)
            add(
              "review.network", declared ? :warning : :error, path, line_number, match.begin(0) + 1,
              declared ? "declared network host requires registry review" : "network host is not declared by package permissions",
              review: true
            )
          rescue URI::InvalidURIError
            add("review.network", :error, path, line_number, match.begin(0) + 1, "network URL is malformed", review: true)
          end
        end
      end

      def host_allowed?(host)
        Array(@manifest.permissions["network_hosts"]).any? do |entry|
          entry == "*" || entry == host || (entry.start_with?("*.") && host.end_with?(entry.delete_prefix("*")))
        end
      end

      def each_match(text, regex)
        offset = 0
        while (match = regex.match(text, offset))
          yield match
          offset = match.begin(0) + 1
        end
      end

      def add(rule, severity, path, line, column, message, review: false)
        if @findings.length >= @policy.limits.fetch("max_findings")
          return if @findings.any? { |item| item.rule_id == "policy.finding-limit" }
          rule = "policy.finding-limit"
          severity = :error
          path = "manifest.yml"
          line = column = nil
          message = "lint finding count exceeds policy"
          review = false
        end
        @findings << Finding.new(
          rule_id: rule.freeze, severity: severity, path: path.to_s.freeze,
          line: line, column: column, message: message.freeze,
          review_required: review, suppression_allowed: !rule.start_with?("secret.", "policy.")
        ).freeze
      end

      def validate_rules!
        unknown = @findings.map(&:rule_id).uniq - @policy.known_rules
        return if unknown.empty?

        @findings.clear
        add("policy.unknown-rule", :error, "manifest.yml", nil, nil, "lint emitted an unknown rule and failed closed")
      end
    end
  end
end
