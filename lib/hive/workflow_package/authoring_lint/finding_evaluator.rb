require "digest"
require "ipaddr"

module Hive
  module WorkflowPackage
    class AuthoringLint
      class FindingEvaluator
        SECRET_PATTERNS = [
          [
            "secret.private-key",
            /-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----/,
            "Private key material detected"
          ],
          [
            "secret.github-token", /\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
            "GitHub credential detected"
          ],
          [
            "secret.openai-key", /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/,
            "OpenAI credential detected"
          ],
          [
            "secret.anthropic-key", /\bsk-ant-[A-Za-z0-9_-]{20,}\b/,
            "Anthropic credential detected"
          ],
          [
            "secret.aws-access-key", /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
            "AWS access key detected"
          ],
          [
            "secret.slack-token", /\bxox[baprs]-[0-9A-Za-z-]{10,}\b/,
            "Slack credential detected"
          ],
          [
            "secret.google-api-key", /\bAIza[0-9A-Za-z_-]{30,}\b/,
            "Google API credential detected"
          ],
          [
            "secret.jwt",
            /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/,
            "JWT-shaped credential detected"
          ],
          [
            "secret.bearer", /\bBearer\s+[A-Za-z0-9._~+\/-]{20,}={0,2}\b/i,
            "Bearer credential detected"
          ]
        ].freeze
        GENERIC_SECRET = /\b(?:api[_-]?key|client[_-]?secret|password|token)\b\s*[:=]\s*["']([^"'\s]{16,})["']/i
        PAYMENT_CARD = /(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)/
        PII_PATTERNS = [
          [
            "pii.government-id",
            /\b(?:ssn|social\s+security(?:\s+number)?|national\s+id)\s*[:#-]?\s*\d{3}-\d{2}-\d{4}\b/i,
            :error, "Context-labeled government identifier detected"
          ],
          [
            "pii.email", /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i,
            :warning, "Email address observed"
          ],
          [
            "pii.phone", /(?<![A-Z0-9])(?:\+?\d[\s().-]*){10,15}(?![A-Z0-9])/i,
            :warning, "Phone-like personal data observed"
          ]
        ].freeze
        DENY_RULES = [
          [
            "deny.pipe-to-shell",
            /\b(?:curl|wget)\b[^\n|]*\|\s*["']?(?:sudo\s+)?(?:ba|z)?sh(?:["']|\s|\z)|\b(?:iwr|invoke-webrequest)\b[^\n|]*\|\s*(?:iex|invoke-expression)\b/i,
            "Network response is piped to a shell"
          ],
          [
            "deny.credential-read",
            %r{(?:~|\$\{?HOME\}?)/(?:\.ssh|\.aws|\.config/gh|\.kube/config|\.npmrc|\.netrc|\.git-credentials|\.docker/config\.json)|/\.aws/credentials}i,
            "Command reads a credential-bearing path"
          ],
          [
            "deny.environment-dump",
            /\A\s*(?:(?:env|printenv)(?:\z|(?!\s*(?:=|<<))\s+)|set\s*\z)/i,
            "Command dumps environment values"
          ],
          [
            "deny.path-traversal", %r{(?:\A|[\s"'])\.\./},
            "Command contains parent traversal"
          ],
          [
            "deny.encoded-exfiltration",
            /\b(?:base64|openssl\s+enc|gzip|tar|zip)\b[^\n|;]*(?:\||;|&&)[^\n]*(?:curl|wget|iwr|invoke-webrequest)\b|\b(?:curl|wget)\b[^\n]*(?:--data(?:-binary)?|-d)\s+[^\n]*(?:base64|gzip|tar|zip)/i,
            "Encoded or compressed data is sent to a network client"
          ]
        ].freeze

        RUBY_PROCESS = /(?:Kernel\.)?(?:system|exec|spawn)\s*\(|Open3\.|IO\.popen|`[^`]+`/
        RUBY_WRITE = /File\.(?:write|binwrite|delete|unlink|rename|chmod|chown|truncate)\b/
        RUBY_READ = /File\.(?:read|binread|open)\b/
        RUBY_NETWORK = /\b(?:Net::H[T]TP|URI[.]open|OpenURI)\b/
        RUBY_SECRET_VARIABLE = /ENV(?:\.fetch\s*\(\s*|\s*\[\s*)["']([A-Z][A-Z0-9_]*(?:TOKEN|KEY|SECRET|PASSWORD)[A-Z0-9_]*)["']/i
        WRITE_COMMAND = /\A\s*(?:sudo\s+)?(?:cp|mv|rm|mkdir|rmdir|chmod|chown|tee|touch|truncate)\b|\bsed\s+-i\b/i
        READ_COMMAND = /\A\s*(?:cat|grep|rg|find|ls|head|tail|sed|awk)\b/i
        ABSOLUTE_PATH = %r{(?:\A|\s)(/(?![/\\])[^\s"']+)}
        SECRET_VARIABLE = /\$(?:\{)?([A-Z][A-Z0-9_]*(?:TOKEN|KEY|SECRET|PASSWORD)[A-Z0-9_]*)(?:\})?/i
        HOST_PATTERN = /\A(?=.{1,259}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}(?::\d{1,5})?\z/
        SHA256 = /\A[0-9a-f]{64}\z/

        class FindingBuffer
          def initialize(policy)
            @policy = policy
            @findings = []
          end

          def replay(events)
            events.each do |event|
              add(
                event.rule_id, event.severity, event.path, event.line, event.column,
                event.message, review: event.review, evidence: event.evidence
              )
            end
          end

          def add(rule, severity, path, line, column, message,
                  review: false, evidence: nil)
            if @findings.length >= @policy.limits.fetch("max_findings")
              return if @findings.any? do |item|
                item.rule_id == "policy.finding-limit"
              end

              @findings.pop
              return add(
                "policy.finding-limit", :error, "manifest.yml", nil, nil,
                "lint finding count exceeds policy"
              )
            end
            evidence ||= message
            fingerprint = ::Digest::SHA256.hexdigest(
              [ rule, path.to_s, line, column, evidence.to_s ].join("\0")
            )
            @findings << Finding.new(
              rule_id: rule.freeze, severity: severity, path: path.to_s.freeze,
              line: line, column: column, message: message.freeze,
              review_required: review,
              suppression_allowed: !rule.start_with?("secret.", "policy."),
              fingerprint: fingerprint.freeze,
              suppression_requested: false
            ).freeze
          end

          def apply_suppression_requests(requests)
            requests.each do |request|
              fingerprint = request.fetch("fingerprint")
              index = @findings.index do |finding|
                finding.fingerprint == fingerprint
              end
              unless index
                add(
                  "suppression.orphaned-request", :error, "manifest.yml", 1, 1,
                  "A suppression request does not match current evidence",
                  evidence: fingerprint
                )
                next
              end

              finding = @findings.fetch(index)
              unless finding.suppression_allowed
                add(
                  "manifest.invalid-security-extension", :error, "manifest.yml",
                  1, 1, "Secret and policy findings cannot be suppressed",
                  evidence: fingerprint
                )
                next
              end
              @findings[index] = finding.with(
                review_required: true, suppression_requested: true
              )
            end
          end

          def validate_rules!
            unknown = @findings.map(&:rule_id).uniq - @policy.known_rules
            return if unknown.empty?

            @findings.clear
            add(
              "policy.unknown-rule", :error, "manifest.yml", nil, nil,
              "lint emitted an unknown rule and failed closed"
            )
          end

          def finish
            @findings.uniq(&:fingerprint)
                     .sort_by do |item|
                       [
                         item.path, item.line || 0, item.column || 0,
                         item.rule_id
                       ]
                     end
                     .freeze
          end
        end

        private_constant :FindingBuffer

        def initialize(policy:)
          @policy = policy
          @buffer = FindingBuffer.new(policy)
        end

        def evaluate(manifest:, package_snapshot:, command_batch:,
                     observation_batch:)
          @manifest = manifest
          @buffer.replay(package_snapshot.events)
          extension = security_extension
          package_snapshot.files.each do |entry|
            scan_patterns(entry) if entry.text
          end
          @buffer.replay(command_batch.events)
          scan_deny_rules(command_batch.commands)
          @buffer.replay(observation_batch.events)
          scan_permissions(
            command_batch.commands, observation_batch.observations, extension
          )
          @buffer.apply_suppression_requests(extension.fetch("suppressions"))
          @buffer.validate_rules!
          @buffer.finish
        end

        private

        def scan_patterns(entry)
          entry.text.each_line.with_index(1) do |line, line_number|
            SECRET_PATTERNS.each do |rule, regex, message|
              each_match(line, regex) do |match|
                add(
                  rule, :error, entry.path, line_number, match.begin(0) + 1,
                  message, evidence: match[0]
                )
              end
            end
            each_match(line, GENERIC_SECRET) do |match|
              next unless entropy(match[1].to_s) >= 3.2

              add(
                "secret.generic-assignment", :error, entry.path, line_number,
                match.begin(0) + 1, "High-entropy credential assignment detected",
                evidence: match[0]
              )
            end
            each_match(line, PAYMENT_CARD) do |match|
              next unless luhn_valid?(match[0])

              add(
                "pii.payment-card", :error, entry.path, line_number,
                match.begin(0) + 1, "Checksum-valid payment card number detected",
                evidence: match[0]
              )
            end
            PII_PATTERNS.each do |rule, regex, severity, message|
              each_match(line, regex) do |match|
                if rule == "pii.phone" &&
                   !match[0].scan(/\d/).length.between?(10, 15)
                  next
                end

                add(
                  rule, severity, entry.path, line_number, match.begin(0) + 1,
                  message, review: severity == :warning, evidence: match[0]
                )
              end
            end
          end
        end

        def scan_deny_rules(commands)
          commands.each do |command|
            DENY_RULES.each do |rule, regex, message|
              match = regex.match(command.raw)
              next unless match

              add(
                rule, :error, command.path, command.line,
                command.column + match.begin(0), message, evidence: match[0]
              )
            end
          end

          downloads = {}
          commands.each do |command|
            match = command.raw.match(
              /\b(?:curl|wget)\b.*?(?:-o|--output|-O)\s+([A-Za-z0-9_.\/-]+)/i
            )
            downloads[File.basename(match[1])] = command if match
          end
          commands.each do |command|
            basenames = command.raw.scan(/[A-Za-z0-9_.\/-]+/)
                               .map { |token| File.basename(token) }.uniq
            basenames.each do |basename|
              download = downloads[basename]
              next unless download && command != download
              next unless command.raw.match?(
                %r{(?:\b(?:bash|sh|zsh|chmod)\b[^\n]*|\./)\b?#{Regexp.escape(basename)}\b}
              )

              add(
                "deny.download-then-execute", :error, command.path,
                command.line, command.column,
                "Downloaded content is subsequently executed", evidence: basename
              )
            end
          end
        end

        def scan_permissions(commands, observations, extension)
          permissions = @manifest.permissions
          capabilities = Array(permissions["capabilities"])
          declared_secrets = Array(permissions["secrets"])
          commands.each do |command|
            if (CommandExtractor.command_start?(command.raw) ||
                command.raw.match?(RUBY_PROCESS)) &&
               !capabilities.include?("shell")
              add_permission(
                "permission.shell", "Observed shell command is not declared",
                command, command.raw
              )
            end
            if (command.raw.match?(WRITE_COMMAND) ||
                command.raw.match?(RUBY_WRITE)) &&
               !capabilities.include?("filesystem-write")
              add_permission(
                "permission.filesystem-write", "Observed write is not declared",
                command, command.raw
              )
            end
            if (command.raw.match?(READ_COMMAND) ||
                command.raw.match?(RUBY_READ)) &&
               !capabilities.include?("filesystem-read")
              add_permission(
                "permission.filesystem-read", "Observed read is not declared",
                command, command.raw
              )
            end
            if (ObservationExtractor.network_command?(command.raw) ||
                command.raw.match?(RUBY_NETWORK)) &&
               !capabilities.include?("network")
              add_permission(
                "permission.network", "Observed network use is not declared",
                command, command.raw
              )
            end
            command.raw.scan(ABSOLUTE_PATH).flatten.each do |path|
              next if path == "/dev/null"

              add_permission(
                "permission.absolute-path",
                "Absolute filesystem path is outside declared scopes",
                command, path
              )
            end
            secret_names =
              command.raw.scan(SECRET_VARIABLE).flatten +
              command.raw.scan(RUBY_SECRET_VARIABLE).flatten
            secret_names.uniq.each do |name|
              next if declared_secrets.include?("*") ||
                      declared_secrets.include?(name)

              add_permission(
                "permission.secret", "Observed secret variable is not declared",
                command, name
              )
            end
          end
          observations.each do |observation|
            scan_network_permission(observation, permissions, extension)
          end
          broad = permissions.any? do |key, value|
            key != "risk" && value.is_a?(Array) && value.include?("*")
          end
          return unless broad || permissions["risk"] == "high"

          add(
            "permission.broad-declaration", :warning, "manifest.yml", 1, 1,
            "Broad declared permissions require human review", review: true,
            evidence: permissions.inspect
          )
        end

        def add_permission(rule, message, command, evidence)
          add(
            rule, :error, command.path, command.line, command.column, message,
            evidence: evidence
          )
        end

        def scan_network_permission(observation, permissions, extension)
          declared_hosts = Array(permissions["network_hosts"])
          reason = extension.fetch("network_host_reasons")
                            .fetch(observation.host, nil)
          declared = !observation.dynamic &&
                     (
                       declared_hosts.include?(observation.host) ||
                       (
                         declared_hosts.include?("*") &&
                         !reason.to_s.strip.empty?
                       )
                     )
          rule, message =
            if observation.dynamic
              [
                "network.dynamic-destination",
                "Network destination is dynamic or unresolved"
              ]
            elsif !declared
              [
                "network.undeclared-host",
                "Observed network host is not declared exactly"
              ]
            elsif ip_literal?(observation.host)
              [
                "network.ip-literal",
                "IP-literal network destinations are not allowed"
              ]
            elsif !@policy.baseline_network_hosts.include?(observation.host) &&
                  reason.to_s.strip.empty?
              [
                "network.missing-reason",
                "Package-specific network host requires a reason"
              ]
            end
          return unless rule

          add(
            rule, :error, observation.path, observation.line,
            observation.column, message, evidence: observation.raw
          )
        end

        def security_extension
          extension = @manifest.data["x-security"]
          return empty_security_extension unless extension

          unless extension.is_a?(Hash) &&
                 extension.keys.sort == %w[network_host_reasons suppressions]
            return invalid_security_extension
          end
          reasons = extension["network_host_reasons"]
          suppressions = extension["suppressions"]
          unless reasons.is_a?(Hash) && suppressions.is_a?(Array)
            return invalid_security_extension
          end

          permission_hosts = Array(@manifest.permissions["network_hosts"])
          valid_reasons = reasons.all? do |host, reason|
            host.is_a?(String) && host == normalize_host(host) &&
              valid_host?(host) &&
              (
                permission_hosts.include?(host) ||
                permission_hosts.include?("*")
              ) &&
              reason.is_a?(String) && !reason.strip.empty?
          end
          seen = {}
          valid_suppressions = suppressions.all? do |request|
            valid = request.is_a?(Hash) &&
                    request.keys.sort == %w[fingerprint reason] &&
                    SHA256.match?(request["fingerprint"].to_s) &&
                    request["reason"].is_a?(String) &&
                    !request["reason"].strip.empty? &&
                    !seen[request["fingerprint"]]
            seen[request["fingerprint"]] = true if valid
            valid
          end
          unless valid_reasons && valid_suppressions
            return invalid_security_extension
          end

          {
            "network_host_reasons" => reasons.sort.to_h.freeze,
            "suppressions" => suppressions
                              .sort_by { |entry| entry.fetch("fingerprint") }
                              .freeze
          }.freeze
        end

        def empty_security_extension
          { "network_host_reasons" => {}, "suppressions" => [] }.freeze
        end

        def invalid_security_extension
          add(
            "manifest.invalid-security-extension", :error, "manifest.yml", 1, 1,
            "The x-security extension is invalid or grants undeclared access"
          )
          empty_security_extension
        end

        def each_match(text, regex)
          offset = 0
          while (match = regex.match(text, offset))
            yield match
            offset = match.begin(0) + 1
          end
        end

        def add(...)
          @buffer.add(...)
        end

        def entropy(value)
          return 0.0 if value.empty?

          value.each_char.tally.values.sum do |count|
            probability = count.fdiv(value.length)
            -probability * Math.log2(probability)
          end
        end

        def luhn_valid?(value)
          digits = value.scan(/\d/).map(&:to_i)
          return false unless digits.length.between?(13, 19)
          return false if digits.uniq.length == 1

          sum = digits.reverse.each_with_index.sum do |digit, index|
            next digit if index.even?

            doubled = digit * 2
            doubled > 9 ? doubled - 9 : doubled
          end
          (sum % 10).zero?
        end

        def normalize_host(host)
          host.to_s.downcase.sub(/\.$/, "")
        end

        def valid_host?(host)
          return false unless HOST_PATTERN.match?(host)

          port = host[/:(\d+)\z/, 1]
          port.nil? || port.to_i.between?(1, 65_535)
        end

        def ip_literal?(host)
          candidate = host.sub(/:\d+\z/, "")
                          .delete_prefix("[").delete_suffix("]")
          IPAddr.new(candidate)
          true
        rescue IPAddr::InvalidAddressError
          false
        end
      end
    end
  end
end
