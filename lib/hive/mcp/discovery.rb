require "digest"
require "json"
require "hive/agent_profiles"
require "hive/agent_support"
require "hive/config"
require "hive/mcp"

module Hive
  module Mcp
    # Read-only discovery of the MCP servers each agent CLI is configured
    # with, for `hive mcp import` (plan 2026-10-15-001, U5). Credential
    # values are looked at only to decide how Hive should reference them;
    # they never leave this module. Login presence is read from each CLI's
    # own store by key, never by value.
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
          candidates.concat(send(:"#{agent}_candidates", cwd: cwd, home: home, env: env, capture: capture))
        rescue Skipped => e
          notices << "#{agent} skipped: #{e.message}"
        end
        Result.new(candidates: candidates.freeze, notices: notices.freeze)
      end

      # --- per-agent sources ---------------------------------------------------

      # `codex mcp list --json` resolves user and trusted-project servers and
      # each one's login state without starting them.
      def codex_candidates(cwd:, env:, capture:, **)
        rows = probe(capture, [ Hive::AgentProfiles.lookup(:codex).bin, "mcp", "list", "--json" ], cwd, "codex")
        raise Skipped, "`codex mcp list --json` returned no server list" unless rows.is_a?(Array)

        user_config = Hive::AgentSupport.for(:codex)::UserConfig.load(
          Hive::AgentSupport.for(:codex)::UserConfig.path(env: env)
        )
        rows.map do |row|
          name = row["name"].to_s
          transport = row["transport"].is_a?(Hash) ? row["transport"] : {}
          raw = case transport["type"]
          when "stdio"
            {
              "command" => transport["command"], "args" => transport["args"] || [],
              "env" => transport["env"] || {}, "cwd" => transport["cwd"],
              "env_from" => Array(transport["env_vars"]).to_h { |var| [ var, var ] }
            }
          when "streamable_http"
            next refused(name, "codex", "its http_headers_helper command cannot be copied") if transport["http_headers_helper"]

            {
              "url" => transport["url"], "headers" => transport["http_headers"] || {},
              "headers_env" => transport["env_http_headers"] || {},
              "bearer_token_env" => transport["bearer_token_env_var"],
              "oauth_resource" => Hive::AgentSupport.for(:codex)::UserConfig.string(
                user_config.table("mcp_servers", name)["oauth_resource"]
              )
            }
          else
            next refused(name, "codex", "transport #{transport['type'].inspect} is not supported")
          end
          status = row["auth_status"]
          candidate(name, "codex", raw, oauth: %w[o_auth not_logged_in].include?(status),
                                        logged_in: status == "o_auth")
        end
      end

      # User (~/.claude.json), project (.mcp.json) and local
      # (projects[cwd] in ~/.claude.json) scopes; the more specific wins.
      def claude_candidates(cwd:, home:, **)
        state = read_json(File.join(home, ".claude.json"), "claude") || {}
        servers = {}
        servers.merge!(hash_at(state, "mcpServers"))
        servers.merge!(hash_at(read_json(File.join(cwd, ".mcp.json"), "claude") || {}, "mcpServers"))
        servers.merge!(hash_at(hash_at(hash_at(state, "projects"), cwd), "mcpServers"))
        logins = hash_at(read_json(File.join(home, ".claude", ".credentials.json"), "claude") || {}, "mcpOAuth").keys
        servers.map do |name, entry|
          next refused(name, "claude", "its entry is not an object") unless entry.is_a?(Hash)

          type = entry["type"] || (entry["url"] ? "http" : "stdio")
          next refused(name, "claude", "transport #{type.inspect} is not supported") unless %w[http stdio].include?(type)

          raw = entry.slice("url", "headers", "command", "args", "env", "cwd")
          logged_in = type == "http" && logins.include?(claude_login_key(name, entry))
          candidate(name, "claude", raw, oauth: logged_in, logged_in: logged_in)
        end
      end

      # Claude keys a saved MCP login by the server name and a hash of its
      # type, url and headers (read from the 2.1.296 bundle; unverified
      # whether `${VAR}` headers are hashed raw or expanded).
      def claude_login_key(name, entry)
        identity = { "type" => entry["type"] || "http", "url" => entry["url"], "headers" => entry["headers"] || {} }
        "#{name}|#{Digest::SHA256.hexdigest(JSON.generate(identity))[0, 16]}"
      end

      def opencode_candidates(cwd:, capture:, **)
        document = probe(capture, [ Hive::AgentProfiles.lookup(:opencode).bin, "debug", "config" ], cwd, "opencode")
        servers = document.is_a?(Hash) ? document["mcp"] || {} : nil
        raise Skipped, "`opencode debug config` returned no mcp table" unless servers.is_a?(Hash)

        servers.map do |name, entry|
          next refused(name, "opencode", "its entry is not an object") unless entry.is_a?(Hash)

          raw = case entry["type"]
          when "remote" then entry.slice("url", "headers")
          when "local"
            command = Array(entry["command"])
            { "command" => command.first, "args" => command.drop(1), "env" => entry["environment"] || {} }
          else next refused(name, "opencode", "transport #{entry['type'].inspect} is not supported")
          end
          candidate(name, "opencode", raw, oauth: entry.key?("oauth"), logged_in: false)
        end
      end

      def pi_candidates(cwd:, home:, env:, **)
        agent_dir = env["PI_CODING_AGENT_DIR"].to_s
        agent_dir = File.join(home, ".pi", "agent") if agent_dir.empty?
        servers = hash_at(read_json(File.join(agent_dir, "mcp.json"), "pi") || {}, "mcpServers")
        project = hash_at(read_json(File.join(cwd, ".pi", "mcp.json"), "pi") || {}, "mcpServers")
        # A project entry without command/url/type only toggles a user server.
        project.each { |name, entry| servers[name] = entry if entry.is_a?(Hash) && (entry.keys & %w[command url type]).any? }
        logins = (read_json(File.join(agent_dir, "mcp-auth.json"), "pi") || {}).keys
        servers.map do |name, entry|
          next refused(name, "pi", "its entry is not an object") unless entry.is_a?(Hash)

          logged_in = logins.any? { |key| key == name || key.start_with?("#{name}|", "#{name}:") }
          candidate(name, "pi", entry.slice("url", "headers", "command", "args", "env", "cwd"),
                    oauth: entry.key?("oauth") || logged_in, logged_in: logged_in)
        end
      end

      def grok_candidates(home:, env:, **)
        grok_home = env["GROK_HOME"].to_s
        grok_home = File.join(home, ".grok") if grok_home.empty?
        path = File.join(grok_home, "config.toml")
        return [] unless File.exist?(path)
        raise Skipped, "#{path} is not readable" unless File.readable?(path)

        user_config = Hive::AgentSupport.for(:codex)::UserConfig
        document = user_config.load(path)
        document.tables_under("mcp_servers").filter_map do |table_path, values|
          next unless table_path.length == 2

          name = table_path.last
          raw = {
            "url" => user_config.string(values["url"]), "command" => user_config.string(values["command"]),
            "args" => toml_array(values["args"]), "env" => toml_table(values["env"]),
            "headers" => toml_table(values["http_headers"]),
            "bearer_token_env" => user_config.string(values["bearer_token_env_var"])
          }.compact
          if raw.values.any?(:invalid)
            next refused(name, "grok", "its config.toml entry uses values Hive cannot read")
          end

          candidate(name, "grok", raw, oauth: false, logged_in: false)
        end
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

      private_class_method :codex_candidates, :claude_candidates, :opencode_candidates, :pi_candidates,
                           :grok_candidates, :http_spec, :stdio_spec, :env_reference, :suggest,
                           :refused, :probe, :read_json, :hash_at, :toml_array, :toml_table
    end
  end
end
