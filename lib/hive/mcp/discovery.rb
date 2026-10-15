require "json"
require "hive/config"
require "hive/mcp"

module Hive
  module Mcp
    # Read-only discovery of the MCP servers each agent CLI is configured
    # with, for `hive mcp import` (plan 2026-10-15-001, U5). Each agent's
    # `AgentSupport::<Agent>::Mcp.discover` reads its own sources; this
    # module normalizes entries to the catalog shape. Credential values are
    # looked at only to decide how Hive should reference them and never
    # leave discovery. Login presence is read by key, never by value.
    module Discovery
      AGENTS = %w[codex claude opencode pi grok].freeze
      PROBE_TIMEOUT_SECONDS = 20
      # `exports` name host env vars the operator must set (a literal
      # credential Hive will not copy); `refusal` explains why the server
      # cannot enter the catalog.
      Candidate = Data.define(:name, :agent, :spec, :oauth, :logged_in, :exports, :refusal)
      Result = Data.define(:candidates, :notices)

      class Skipped < StandardError; end

      ENV_REFERENCE = /\A(?:\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\{env:([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*))\z/
      INTERPOLATION = /\$\{|\{env:|\A!/

      module_function

      def discover(cwd:, home: Dir.home, env: ENV, capture: Hive::Mcp.method(:capture))
        candidates = []
        notices = []
        AGENTS.each do |agent|
          candidates.concat(Hive::Mcp.adapter(agent).discover(cwd: cwd, home: home, env: env, capture: capture))
        rescue Skipped => e
          notices << "#{agent} skipped: #{e.message}"
        end
        Result.new(candidates: candidates.freeze, notices: notices.freeze)
      end

      # --- normalization ---------------------------------------------------------

      # Map one agent's entry to the catalog shape. Credentials become env-var
      # references; a literal credential is replaced by a suggested variable
      # the operator must export, and is never written.
      def candidate(name, agent, raw, oauth:, logged_in:)
        exports = []
        spec = raw["url"] ? http_spec(name, agent, raw, exports) : stdio_spec(name, agent, raw, exports)
        Hive::Config.validate_mcp_server!(name, spec, "#{agent} MCP config")
        Candidate.new(name: name, agent: agent, spec: spec.freeze, oauth: oauth, logged_in: logged_in,
                      exports: exports.freeze, refusal: nil)
      rescue Refused, Hive::ConfigError => e
        refused(name, agent, e.message.sub(" (defaults; no file present)", ""))
      end

      class Refused < StandardError; end

      def http_spec(name, agent, raw, exports)
        headers = {}
        headers_env = (raw["headers_env"] || {}).dup
        bearer = raw["bearer_token_env"]
        (raw["headers"] || {}).each do |header, value|
          value = value.to_s
          if header.casecmp?("authorization")
            token = value[/\ABearer\s+(.+)\z/i, 1] or raise Refused, "its Authorization header is not a bearer token"
            bearer = env_reference(token) || suggest(name, "TOKEN", "#{name} Authorization header (#{agent})", exports)
          elsif (variable = env_reference(value))
            headers_env[header] = variable
          elsif value.match?(INTERPOLATION)
            raise Refused, "its #{header} header builds its value from a command or partial variable"
          elsif Hive::Config.mcp_secret_header?(header)
            headers_env[header] = suggest(name, header, "#{name} #{header} header (#{agent})", exports)
          else
            headers[header] = value
          end
        end
        {
          "url" => raw["url"], "bearer_token_env" => bearer,
          "headers" => headers.empty? ? nil : headers,
          "headers_env" => headers_env.empty? ? nil : headers_env,
          "oauth_resource" => raw["oauth_resource"]
        }.compact
      end

      def stdio_spec(name, agent, raw, exports)
        env = {}
        env_from = (raw["env_from"] || {}).dup
        (raw["env"] || {}).each do |key, value|
          value = value.to_s
          if (variable = env_reference(value))
            env_from[key] = variable
          elsif value.match?(INTERPOLATION)
            raise Refused, "its #{key} environment value builds itself from a command or partial variable"
          elsif key.match?(Hive::Config::MCP_SECRET_NAME)
            env_from[key] = key
            exports << { "var" => key, "for" => "#{name} #{key} environment value (#{agent})" }
          else
            env[key] = value
          end
        end
        {
          "command" => raw["command"], "args" => Array(raw["args"]).map(&:to_s),
          "env" => env.empty? ? nil : env, "env_from" => env_from.empty? ? nil : env_from,
          "cwd" => raw["cwd"]
        }.compact
      end

      def env_reference(value)
        match = value.to_s.strip.match(ENV_REFERENCE)
        match && (match[1] || match[2] || match[3])
      end

      def suggest(name, label, description, exports)
        variable = "#{name}_#{label}".upcase.gsub(/[^A-Z0-9]+/, "_")
        exports << { "var" => variable, "for" => description }
        variable
      end

      def refused(name, agent, reason)
        Candidate.new(name: name.to_s, agent: agent, spec: nil, oauth: false, logged_in: false,
                      exports: [].freeze, refusal: reason)
      end

      # --- readers -------------------------------------------------------------

      def probe(capture, argv, cwd, agent)
        stdout, status = capture.call(argv, chdir: cwd, timeout: PROBE_TIMEOUT_SECONDS)
        raise Skipped, "`#{agent} #{argv.drop(1).join(' ')}` exited #{status.exitstatus}" unless status.success?

        JSON.parse(stdout)
      rescue JSON::ParserError
        raise Skipped, "`#{agent} #{argv.drop(1).join(' ')}` returned malformed JSON"
      rescue Hive::AgentError => e
        raise Skipped, e.message
      rescue SystemCallError => e
        raise Skipped, "#{agent} could not run (#{e.class.name.split('::').last})"
      end

      def read_json(path, agent)
        JSON.parse(File.read(path))
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      rescue JSON::ParserError, SystemCallError => e
        raise Skipped, "#{path} could not be read (#{e.class.name.split('::').last})"
      end

      def hash_at(document, key)
        value = document.is_a?(Hash) ? document[key] : nil
        value.is_a?(Hash) ? value.dup : {}
      end

      def toml_array(raw)
        return if raw.nil?

        value = JSON.parse(raw)
        value.is_a?(Array) && value.all?(String) ? value : :invalid
      rescue JSON::ParserError
        :invalid
      end

      def toml_table(raw)
        return if raw.nil?

        body = raw.strip.delete_prefix("{").delete_suffix("}").strip
        pairs = body.empty? ? [] : body.split(/\s*,\s*/)
        pairs.to_h do |pair|
          key, value = pair.split(/\s*=\s*/, 2)
          return :invalid unless key && value&.match?(/\A"(?:[^"\\]|\\.)*"\z/)

          [ key.delete('"'), JSON.parse(value) ]
        end
      end

      private_class_method :http_spec, :stdio_spec, :env_reference, :suggest
    end
  end
end
