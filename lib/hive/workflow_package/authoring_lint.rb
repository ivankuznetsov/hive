require "digest"
require "find"
require "ipaddr"
require "psych"
require "shellwords"
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
        :review_required, :suppression_allowed, :fingerprint, :suppression_requested
      ) do
        def error? = severity == :error
        def warning? = severity == :warning

        def to_h
          {
            "rule_id" => rule_id, "severity" => severity.to_s, "path" => path,
            "line" => line, "column" => column, "message" => message,
            "review_required" => review_required,
            "suppression_allowed" => suppression_allowed,
            "fingerprint" => fingerprint,
            "suppression_requested" => suppression_requested
          }.compact.freeze
        end
      end

      Result = Data.define(:contract, :findings) do
        def errors = findings.select(&:error?)
        def warnings = findings.select(&:warning?)
        def valid? = errors.empty?
      end

      FileEntry = Data.define(:path, :bytes, :text)
      Command = Data.define(:path, :line, :column, :raw)
      Observation = Data.define(:host, :dynamic, :path, :line, :column, :raw)

      SECRET_PATTERNS = [
        [ "secret.private-key", /-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----/, "Private key material detected" ],
        [ "secret.github-token", /\bgh[pousr]_[A-Za-z0-9]{20,}\b/, "GitHub credential detected" ],
        [ "secret.openai-key", /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/, "OpenAI credential detected" ],
        [ "secret.anthropic-key", /\bsk-ant-[A-Za-z0-9_-]{20,}\b/, "Anthropic credential detected" ],
        [ "secret.aws-access-key", /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/, "AWS access key detected" ],
        [ "secret.slack-token", /\bxox[baprs]-[0-9A-Za-z-]{10,}\b/, "Slack credential detected" ],
        [ "secret.google-api-key", /\bAIza[0-9A-Za-z_-]{30,}\b/, "Google API credential detected" ],
        [ "secret.jwt", /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/, "JWT-shaped credential detected" ],
        [ "secret.bearer", /\bBearer\s+[A-Za-z0-9._~+\/-]{20,}={0,2}\b/i, "Bearer credential detected" ]
      ].freeze
      GENERIC_SECRET = /\b(?:api[_-]?key|client[_-]?secret|password|token)\b\s*[:=]\s*["']([^"'\s]{16,})["']/i
      PAYMENT_CARD = /(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)/
      PII_PATTERNS = [
        [ "pii.government-id", /\b(?:ssn|social\s+security(?:\s+number)?|national\s+id)\s*[:#-]?\s*\d{3}-\d{2}-\d{4}\b/i, :error, "Context-labeled government identifier detected" ],
        [ "pii.email", /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i, :warning, "Email address observed" ],
        [ "pii.phone", /(?<![A-Z0-9])(?:\+?\d[\s().-]*){10,15}(?![A-Z0-9])/i, :warning, "Phone-like personal data observed" ]
      ].freeze
      DENY_RULES = [
        [ "deny.pipe-to-shell", /\b(?:curl|wget)\b[^\n|]*\|\s*["']?(?:sudo\s+)?(?:ba|z)?sh(?:["']|\s|\z)|\b(?:iwr|invoke-webrequest)\b[^\n|]*\|\s*(?:iex|invoke-expression)\b/i, "Network response is piped to a shell" ],
        [ "deny.credential-read", %r{(?:~|\$\{?HOME\}?)/(?:\.ssh|\.aws|\.config/gh|\.kube/config|\.npmrc|\.netrc|\.git-credentials|\.docker/config\.json)|/\.aws/credentials}i, "Command reads a credential-bearing path" ],
        [ "deny.environment-dump", /\A\s*(?:(?:env|printenv)(?:\z|(?!\s*(?:=|<<))\s+)|set\s*\z)/i, "Command dumps environment values" ],
        [ "deny.path-traversal", %r{(?:\A|[\s"'])\.\./}, "Command contains parent traversal" ],
        [ "deny.encoded-exfiltration", /\b(?:base64|openssl\s+enc|gzip|tar|zip)\b[^\n|;]*(?:\||;|&&)[^\n]*(?:curl|wget|iwr|invoke-webrequest)\b|\b(?:curl|wget)\b[^\n]*(?:--data(?:-binary)?|-d)\s+[^\n]*(?:base64|gzip|tar|zip)/i, "Encoded or compressed data is sent to a network client" ]
      ].freeze

      COMMAND_START = /\A\s*(?:\$\s*)?(?:(?:bash|sh|zsh|pwsh|powershell|curl|wget|iwr|invoke-webrequest|git|gh|ruby|python\d*|node|npm|npx|bundle|rake|cat|grep|rg|find|ls|head|tail|sed|awk|tar|zip|gzip|base64|openssl|env|printenv|export|set|cp|mv|rm|mkdir|chmod|chown|tee|echo|printf|source)\b|\.\/[^\s]+)(?:\s|[|;&<>()]|\z)/i
      SHELL_FENCE = /\A\s*```\s*(bash|sh|shell|zsh|powershell|pwsh)?\s*\z/i
      RUBY_SINK = %r{
        https?://|(?:Kernel\.)?(?:system|exec|spawn)\s*\(|Open3\.|IO\.popen|`[^`]+`|
        File\.(?:read|binread|open|write|binwrite|delete|unlink|rename|chmod|chown|truncate)|
        (?:Net::H[T]TP|URI[.]open|OpenURI)|ENV(?:\.fetch\s*\(|\s*\[)
      }ix
      RUBY_PROCESS = /(?:Kernel\.)?(?:system|exec|spawn)\s*\(|Open3\.|IO\.popen|`[^`]+`/
      RUBY_WRITE = /File\.(?:write|binwrite|delete|unlink|rename|chmod|chown|truncate)\b/
      RUBY_READ = /File\.(?:read|binread|open)\b/
      RUBY_NETWORK = /\b(?:Net::H[T]TP|URI[.]open|OpenURI)\b/
      RUBY_SECRET_VARIABLE = /ENV(?:\.fetch\s*\(\s*|\s*\[\s*)["']([A-Z][A-Z0-9_]*(?:TOKEN|KEY|SECRET|PASSWORD)[A-Z0-9_]*)["']/i
      WRITE_COMMAND = /\A\s*(?:sudo\s+)?(?:cp|mv|rm|mkdir|rmdir|chmod|chown|tee|touch|truncate)\b|\bsed\s+-i\b/i
      READ_COMMAND = /\A\s*(?:cat|grep|rg|find|ls|head|tail|sed|awk)\b/i
      NETWORK_COMMAND = /\b(?:curl|wget|iwr|invoke-webrequest|Net::H[T]TP|URI[.]open|OpenURI)\b/i
      ABSOLUTE_PATH = %r{(?:\A|\s)(/(?![/\\])[^\s"']+)}
      SECRET_VARIABLE = /\$(?:\{)?([A-Z][A-Z0-9_]*(?:TOKEN|KEY|SECRET|PASSWORD)[A-Z0-9_]*)(?:\})?/i
      URL_PATTERN = %r{https?://[^\s"'<>|`]+}i
      CURL_VALUE_OPTIONS = %w[
        -A --data --data-ascii --data-binary --data-raw --data-urlencode --form --header
        --output --referer --request --user --user-agent -d -e -F -H -o -u -X
      ].freeze
      WGET_VALUE_OPTIONS = %w[
        --header --output-document --referer --user --user-agent -e -o -O -U
      ].freeze
      POWERSHELL_VALUE_OPTIONS = %w[-Headers -Method -OutFile -UserAgent].map(&:downcase).freeze
      HOST_PATTERN = /\A(?=.{1,259}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}(?::\d{1,5})?\z/
      SHA256 = /\A[0-9a-f]{64}\z/

      def self.verify(root, manifest:, policy: nil)
        new(root, manifest: manifest, policy: policy || LintPolicy.load).verify
      rescue StandardError => e
        raise if e.is_a?(Hive::ConfigError)

        finding = Finding.new(
          rule_id: "policy.scanner-error", severity: :error, path: "manifest.yml",
          line: nil, column: nil, message: "local Honeycomb scanner failed closed",
          review_required: false, suppression_allowed: false,
          fingerprint: ::Digest::SHA256.hexdigest("policy.scanner-error"),
          suppression_requested: false
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
        extension = security_extension
        files.each { |entry| scan_patterns(entry) if entry.text }
        commands = extract_commands(files)
        scan_deny_rules(commands)
        observations = extract_network(commands)
        scan_permissions(commands, observations, extension)
        apply_suppression_requests(extension.fetch("suppressions"))
        validate_rules!
        findings = @findings.uniq(&:fingerprint)
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
          if entries.length >= @policy.limits.fetch("max_files")
            add("policy.file-limit", :error, relative, nil, nil, "package file count exceeds lint policy")
            break
          end
          if stat.size > @policy.limits.fetch("max_file_bytes")
            add("policy.file-limit", :error, relative, nil, nil, "package file exceeds lint byte limit")
            next
          end
          bytes = File.binread(path)
          current = File.lstat(path)
          unless current.file? && !current.symlink? && current.dev == stat.dev &&
                 current.ino == stat.ino && current.size == bytes.bytesize
            add("policy.invalid-file", :error, relative, nil, nil, "package file changed while being scanned")
            next
          end
          total += bytes.bytesize
          if total > @policy.limits.fetch("max_total_bytes")
            add("policy.total-limit", :error, relative, nil, nil, "package total bytes exceed lint policy")
            break
          end
          text = decode_text(bytes, relative)
          entries << FileEntry.new(path: relative.freeze, bytes: bytes.freeze, text: text&.freeze).freeze
        end
        entries.sort_by(&:path)
      rescue SystemCallError, IOError
        add("policy.invalid-file", :error, "", nil, nil, "package files could not be read safely")
        []
      end

      def decode_text(bytes, path)
        return nil if bytes.include?("\0")

        text = bytes.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding?
          add("policy.invalid-encoding", :error, path, nil, nil, "text input is not valid UTF-8")
          return nil
        end
        text
      end

      def scan_patterns(entry)
        entry.text.each_line.with_index(1) do |line, line_number|
          SECRET_PATTERNS.each do |rule, regex, message|
            each_match(line, regex) do |match|
              add(rule, :error, entry.path, line_number, match.begin(0) + 1, message, evidence: match[0])
            end
          end
          each_match(line, GENERIC_SECRET) do |match|
            next unless entropy(match[1].to_s) >= 3.2

            add(
              "secret.generic-assignment", :error, entry.path, line_number, match.begin(0) + 1,
              "High-entropy credential assignment detected", evidence: match[0]
            )
          end
          each_match(line, PAYMENT_CARD) do |match|
            next unless luhn_valid?(match[0])

            add(
              "pii.payment-card", :error, entry.path, line_number, match.begin(0) + 1,
              "Checksum-valid payment card number detected", evidence: match[0]
            )
          end
          PII_PATTERNS.each do |rule, regex, severity, message|
            each_match(line, regex) do |match|
              next if rule == "pii.phone" && !match[0].scan(/\d/).length.between?(10, 15)

              add(
                rule, severity, entry.path, line_number, match.begin(0) + 1, message,
                review: severity == :warning, evidence: match[0]
              )
            end
          end
        end
      end

      def extract_commands(files)
        @command_count = 0
        behavior_paths = declared_behavior_paths
        scoped = files.select do |entry|
          entry.path == "workflow.yml" || entry.path == "README.md" ||
            entry.path.start_with?("instructions/") || behavior_paths.include?(entry.path)
        end
        scoped.flat_map do |entry|
          unless entry.text
            add(
              "policy.invalid-file", :error, entry.path, nil, nil,
              "declared behavior must be scannable UTF-8 text"
            )
            next []
          end

          if entry.path.match?(/\.ya?ml\z/i)
            extract_yaml(entry)
          elsif executable_path?(entry.path)
            extract_executable(entry)
          else
            extract_markdown(entry)
          end
        end.sort_by { |command| [ command.path, command.line, command.column, command.raw ] }
      end

      def declared_behavior_paths
        extension = @manifest.data["x-hive"]
        return [] unless extension.is_a?(Hash)

        %w[tools prompt_assets].flat_map do |key|
          Array(extension[key]).filter_map do |entry|
            entry["path"] if entry.is_a?(Hash) && entry["path"].is_a?(String)
          end
        end.uniq
      end

      def executable_path?(path)
        extension = @manifest.data["x-hive"]
        Array(extension.is_a?(Hash) && extension["tools"]).any? do |entry|
          entry.is_a?(Hash) && entry["path"] == path
        end
      end

      def extract_executable(entry)
        return extract_ruby(entry) if entry.path.match?(/\.rb\z/i)
        return extract_markdown(entry) if entry.path.match?(/\.(?:sh|bash|zsh|ps1)\z/i) || File.extname(entry.path).empty?

        add(
          "policy.invalid-file", :error, entry.path, nil, nil,
          "declared executable type is unsupported by the lint contract"
        )
        []
      end

      def extract_ruby(entry)
        entry.text.each_line.with_index(1).filter_map do |line, line_number|
          next unless line.match?(RUBY_SINK)

          append_command(Command.new(
            path: entry.path, line: line_number, column: first_column(line), raw: line.chomp
          ).freeze)
        end
      end

      def extract_markdown(entry)
        commands = []
        fence = nil
        entry.text.each_line.with_index(1) do |line, line_number|
          stripped = line.chomp
          if (opening = SHELL_FENCE.match(stripped))
            fence = fence ? nil : { shell: !opening[1].nil? }
            next
          end
          if fence
            if !stripped.strip.empty? && (fence.fetch(:shell) || command_like?(stripped))
              command = append_command(Command.new(
                path: entry.path, line: line_number, column: first_column(line), raw: stripped
              ).freeze)
              commands << command if command
            end
            next
          end
          if !stripped.strip.empty? && command_like?(stripped)
            command = append_command(Command.new(
              path: entry.path, line: line_number, column: first_column(line), raw: stripped
            ).freeze)
            commands << command if command
          end
          line.to_enum(:scan, /`([^`\r\n]+)`/).each do
            match = Regexp.last_match
            next unless command_like?(match[1])

            command = append_command(Command.new(
              path: entry.path, line: line_number, column: match.begin(1) + 1, raw: match[1]
            ).freeze)
            commands << command if command
          end
        end
        commands
      end

      def extract_yaml(entry)
        stream = Psych.parse_stream(entry.text, filename: entry.path)
        commands = []
        walk_yaml(stream, entry.path, commands, mapping_key: false, yaml_path: [])
        commands
      rescue Psych::Exception
        add(
          "instruction.malformed-yaml", :error, entry.path, nil, nil,
          "instruction YAML could not be parsed safely"
        )
        []
      end

      def walk_yaml(node, path, commands, mapping_key:, yaml_path:)
        case node
        when Psych::Nodes::Mapping
          node.children.each_slice(2) do |key, value|
            walk_yaml(key, path, commands, mapping_key: true, yaml_path: yaml_path)
            child_path = key.is_a?(Psych::Nodes::Scalar) ? yaml_path + [ key.value ] : yaml_path
            walk_yaml(value, path, commands, mapping_key: false, yaml_path: child_path)
          end
        when Psych::Nodes::Sequence, Psych::Nodes::Stream, Psych::Nodes::Document
          node.children.each do |child|
            walk_yaml(child, path, commands, mapping_key: false, yaml_path: yaml_path)
          end
        when Psych::Nodes::Scalar
          return if mapping_key || !yaml_string?(node) || workflow_permission_field?(path, yaml_path)

          lines = node.value.lines
          if lines.length > 1
            lines.each_with_index do |line, index|
              raw = line.chomp
              next unless command_like?(raw)

              command = append_command(Command.new(
                path: path, line: node.start_line + index + 1, column: 1, raw: raw
              ).freeze)
              commands << command if command
            end
          elsif command_like?(node.value)
            command = append_command(Command.new(
              path: path, line: node.start_line + 1, column: node.start_column + 1, raw: node.value
            ).freeze)
            commands << command if command
          end
        end
      end

      def yaml_string?(node)
        return true if node.quoted || node.style != Psych::Nodes::Scalar::PLAIN
        return false if node.tag && node.tag != "tag:yaml.org,2002:str"

        !node.value.match?(/\A(?:null|~|true|false|yes|no|on|off|[-+]?\d+(?:\.\d+)?)\z/i)
      end

      def workflow_permission_field?(path, yaml_path)
        return false unless path == "workflow.yml" && yaml_path.first == "stages"

        yaml_path.each_cons(2).any? do |parent, field|
          parent == "permissions" && %w[tools dirs].include?(field)
        end
      end

      def append_command(command)
        if @command_count >= @policy.limits.fetch("max_commands")
          add(
            "policy.command-limit", :error, command.path, command.line, command.column,
            "extracted command count exceeds lint policy"
          )
          return nil
        end
        @command_count += 1
        command
      end

      def command_like?(value)
        value.to_s.match?(COMMAND_START) || value.to_s.match?(/\|\s*(?:sh|bash|zsh|pwsh|powershell)\b/i)
      end

      def scan_deny_rules(commands)
        commands.each do |command|
          DENY_RULES.each do |rule, regex, message|
            match = regex.match(command.raw)
            next unless match

            add(
              rule, :error, command.path, command.line, command.column + match.begin(0),
              message, evidence: match[0]
            )
          end
        end

        downloads = {}
        commands.each do |command|
          match = command.raw.match(/\b(?:curl|wget)\b.*?(?:-o|--output|-O)\s+([A-Za-z0-9_.\/-]+)/i)
          downloads[File.basename(match[1])] = command if match
        end
        commands.each do |command|
          command.raw.scan(/[A-Za-z0-9_.\/-]+/).map { |token| File.basename(token) }.uniq.each do |basename|
            download = downloads[basename]
            next unless download && command != download
            next unless command.raw.match?(%r{(?:\b(?:bash|sh|zsh|chmod)\b[^\n]*|\./)\b?#{Regexp.escape(basename)}\b})

            add(
              "deny.download-then-execute", :error, command.path, command.line, command.column,
              "Downloaded content is subsequently executed", evidence: basename
            )
          end
        end
      end

      def extract_network(commands)
        observations = []
        commands.each do |command|
          before = observations.length
          command.raw.to_enum(:scan, URL_PATTERN).each do
            match = Regexp.last_match
            raw = match[0].sub(/[),.;]+\z/, "")
            append_observation(observations, observation(command, raw, match.begin(0) + 1))
          end
          unresolved_fallback = observations.length == before
          destination = dynamic_destination(command.raw, unresolved_fallback)
          next unless command.raw.match?(NETWORK_COMMAND) && destination

          append_observation(
            observations,
            Observation.new(
              host: destination, dynamic: true, path: command.path, line: command.line,
              column: command.column, raw: destination
            ).freeze
          )
        end
        observations.uniq { |entry| [ entry.host, entry.path, entry.line, entry.column ] }
                    .sort_by { |entry| [ entry.path, entry.line, entry.column, entry.host ] }
      end

      def append_observation(observations, observation)
        if observations.length >= @policy.limits.fetch("max_observations")
          add(
            "policy.observation-limit", :error, observation.path, observation.line, observation.column,
            "network observation count exceeds lint policy"
          )
          return
        end
        observations << observation
      end

      def observation(command, raw, offset)
        dynamic = raw.match?(/\$|\{\{|%[A-Za-z_]+%/)
        host = dynamic ? "<dynamic>" : normalize_uri(raw)
        Observation.new(
          host: host, dynamic: dynamic, path: command.path, line: command.line,
          column: command.column + offset - 1, raw: raw
        ).freeze
      rescue URI::InvalidURIError
        Observation.new(
          host: "<invalid>", dynamic: true, path: command.path, line: command.line,
          column: command.column + offset - 1, raw: raw
        ).freeze
      end

      def normalize_uri(raw)
        uri = URI.parse(raw)
        raise URI::InvalidURIError if uri.userinfo || uri.host.nil?

        host = uri.host.downcase.sub(/\.$/, "")
        default_port = uri.scheme.downcase == "https" ? 443 : 80
        uri.port == default_port ? host : "#{host}:#{uri.port}"
      end

      def dynamic_destination(raw, unresolved_fallback)
        tokens = Shellwords.shellsplit(raw)
        command_index = tokens.index { |token| token.match?(NETWORK_COMMAND) }
        return "<unresolved>" if unresolved_fallback && command_index.nil?
        return nil unless command_index

        client = File.basename(tokens.fetch(command_index)).downcase
        arguments = tokens.drop(command_index + 1)
        index = 0
        while index < arguments.length
          token = arguments[index]
          option, attached_value = token.split("=", 2)
          if destination_option?(client, option)
            value = attached_value || arguments[index + 1]
            return "<dynamic>" if dynamic_token?(value)
            index += attached_value ? 1 : 2
            next
          end
          if token.start_with?("-")
            consumes_value = attached_value.nil? && value_option?(client, token)
            index += consumes_value ? 2 : 1
            next
          end
          return "<dynamic>" if dynamic_token?(token)

          index += 1
        end
        "<unresolved>" if unresolved_fallback
      rescue ArgumentError
        "<dynamic>"
      end

      def destination_option?(client, option)
        (client == "curl" && option == "--url") ||
          (%w[iwr invoke-webrequest].include?(client) && option.casecmp?("-Uri"))
      end

      def value_option?(client, token)
        case client
        when "curl" then CURL_VALUE_OPTIONS.include?(token)
        when "wget" then WGET_VALUE_OPTIONS.include?(token)
        when "iwr", "invoke-webrequest" then POWERSHELL_VALUE_OPTIONS.include?(token.downcase)
        else false
        end
      end

      def dynamic_token?(token)
        token.to_s.match?(/\$|\{\{|%[A-Za-z_]+%/)
      end

      def scan_permissions(commands, observations, extension)
        permissions = @manifest.permissions
        capabilities = Array(permissions["capabilities"])
        declared_secrets = Array(permissions["secrets"])
        commands.each do |command|
          if (command.raw.match?(COMMAND_START) || command.raw.match?(RUBY_PROCESS)) && !capabilities.include?("shell")
            add_permission("permission.shell", "Observed shell command is not declared", command, command.raw)
          end
          if (command.raw.match?(WRITE_COMMAND) || command.raw.match?(RUBY_WRITE)) && !capabilities.include?("filesystem-write")
            add_permission("permission.filesystem-write", "Observed write is not declared", command, command.raw)
          end
          if (command.raw.match?(READ_COMMAND) || command.raw.match?(RUBY_READ)) && !capabilities.include?("filesystem-read")
            add_permission("permission.filesystem-read", "Observed read is not declared", command, command.raw)
          end
          if (command.raw.match?(NETWORK_COMMAND) || command.raw.match?(RUBY_NETWORK)) && !capabilities.include?("network")
            add_permission("permission.network", "Observed network use is not declared", command, command.raw)
          end
          command.raw.scan(ABSOLUTE_PATH).flatten.each do |path|
            next if path == "/dev/null"

            add_permission(
              "permission.absolute-path", "Absolute filesystem path is outside declared scopes",
              command, path
            )
          end
          (command.raw.scan(SECRET_VARIABLE).flatten + command.raw.scan(RUBY_SECRET_VARIABLE).flatten).uniq.each do |name|
            next if declared_secrets.include?("*") || declared_secrets.include?(name)

            add_permission("permission.secret", "Observed secret variable is not declared", command, name)
          end
        end
        observations.each { |observation| scan_network_permission(observation, permissions, extension) }
        broad = permissions.any? do |key, value|
          key != "risk" && value.is_a?(Array) && value.include?("*")
        end
        if broad || permissions["risk"] == "high"
          add(
            "permission.broad-declaration", :warning, "manifest.yml", 1, 1,
            "Broad declared permissions require human review", review: true,
            evidence: permissions.inspect
          )
        end
      end

      def add_permission(rule, message, command, evidence)
        add(
          rule, :error, command.path, command.line, command.column, message,
          evidence: evidence
        )
      end

      def scan_network_permission(observation, permissions, extension)
        declared_hosts = Array(permissions["network_hosts"])
        reason = extension.fetch("network_host_reasons").fetch(observation.host, nil)
        declared = !observation.dynamic &&
                   (declared_hosts.include?(observation.host) ||
                    (declared_hosts.include?("*") && !reason.to_s.strip.empty?))
        rule, message =
          if observation.dynamic
            [ "network.dynamic-destination", "Network destination is dynamic or unresolved" ]
          elsif !declared
            [ "network.undeclared-host", "Observed network host is not declared exactly" ]
          elsif ip_literal?(observation.host)
            [ "network.ip-literal", "IP-literal network destinations are not allowed" ]
          elsif !@policy.baseline_network_hosts.include?(observation.host) &&
                reason.to_s.strip.empty?
            [ "network.missing-reason", "Package-specific network host requires a reason" ]
          end
        return unless rule

        add(
          rule, :error, observation.path, observation.line, observation.column, message,
          evidence: observation.raw
        )
      end

      def security_extension
        extension = @manifest.data["x-security"]
        return { "network_host_reasons" => {}, "suppressions" => [] } unless extension

        unless extension.is_a?(Hash) && extension.keys.sort == %w[network_host_reasons suppressions]
          return invalid_security_extension
        end
        reasons = extension["network_host_reasons"]
        suppressions = extension["suppressions"]
        return invalid_security_extension unless reasons.is_a?(Hash) && suppressions.is_a?(Array)

        permission_hosts = Array(@manifest.permissions["network_hosts"])
        valid_reasons = reasons.all? do |host, reason|
          host.is_a?(String) && host == normalize_host(host) && valid_host?(host) &&
            (permission_hosts.include?(host) || permission_hosts.include?("*")) &&
            reason.is_a?(String) && !reason.strip.empty?
        end
        seen = {}
        valid_suppressions = suppressions.all? do |request|
          valid = request.is_a?(Hash) && request.keys.sort == %w[fingerprint reason] &&
                  SHA256.match?(request["fingerprint"].to_s) &&
                  request["reason"].is_a?(String) && !request["reason"].strip.empty? &&
                  !seen[request["fingerprint"]]
          seen[request["fingerprint"]] = true if valid
          valid
        end
        return invalid_security_extension unless valid_reasons && valid_suppressions

        {
          "network_host_reasons" => reasons.sort.to_h.freeze,
          "suppressions" => suppressions.sort_by { |entry| entry.fetch("fingerprint") }.freeze
        }.freeze
      end

      def invalid_security_extension
        add(
          "manifest.invalid-security-extension", :error, "manifest.yml", 1, 1,
          "The x-security extension is invalid or grants undeclared access"
        )
        { "network_host_reasons" => {}, "suppressions" => [] }.freeze
      end

      def apply_suppression_requests(requests)
        requests.each do |request|
          fingerprint = request.fetch("fingerprint")
          index = @findings.index { |finding| finding.fingerprint == fingerprint }
          unless index
            add(
              "suppression.orphaned-request", :error, "manifest.yml", 1, 1,
              "A suppression request does not match current evidence", evidence: fingerprint
            )
            next
          end

          finding = @findings.fetch(index)
          unless finding.suppression_allowed
            add(
              "manifest.invalid-security-extension", :error, "manifest.yml", 1, 1,
              "Secret and policy findings cannot be suppressed", evidence: fingerprint
            )
            next
          end
          @findings[index] = finding.with(review_required: true, suppression_requested: true)
        end
      end

      def each_match(text, regex)
        offset = 0
        while (match = regex.match(text, offset))
          yield match
          offset = match.begin(0) + 1
        end
      end

      def add(rule, severity, path, line, column, message, review: false, evidence: nil)
        if @findings.length >= @policy.limits.fetch("max_findings")
          return if @findings.any? { |item| item.rule_id == "policy.finding-limit" }

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

      def validate_rules!
        unknown = @findings.map(&:rule_id).uniq - @policy.known_rules
        return if unknown.empty?

        @findings.clear
        add(
          "policy.unknown-rule", :error, "manifest.yml", nil, nil,
          "lint emitted an unknown rule and failed closed"
        )
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
        candidate = host.sub(/:\d+\z/, "").delete_prefix("[").delete_suffix("]")
        IPAddr.new(candidate)
        true
      rescue IPAddr::InvalidAddressError
        false
      end

      def first_column(line)
        line.index(/\S/) ? line.index(/\S/) + 1 : 1
      end
    end
  end
end
