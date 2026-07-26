require "json"
require "open3"
require "tempfile"
require "yaml"
require "hive/config"
require "hive/env_file"
require "hive/gh"
require "hive/invoked_binary"
require "hive/london_date"
require "hive/paths"
require "hive/repository_identity"

module Hive
  module Prdigest
    SCHEMA = "prdigest-result".freeze
    SCHEMA_VERSION = 1
    REPOSITORY_SEGMENT = /\A[A-Za-z0-9_.-]+\z/

    Result = Data.define(:payload, :exit_code, :repositories, :argv) do
      def success?
        exit_code.zero?
      end
    end

    class InvocationError < Hive::Error
      attr_reader :payload

      def initialize(result)
        @payload = result.payload
        @exit_code = result.exit_code
        error = payload["error"]
        kind = error.is_a?(Hash) ? error["kind"].to_s : "failure"
        message = error.is_a?(Hash) ? error["message"].to_s : "PRDigest failed"
        super("prdigest #{kind}: #{message}")
      end

      def exit_code
        @exit_code
      end
    end

    class Registry
      def initialize(entries: nil, entries_loader: Hive::Config.method(:digest_registered_projects),
                     identity_resolver: Hive::RepositoryIdentity.method(:current),
                     origin_absence_resolver: Hive::RepositoryIdentity.method(:origin_absent?))
        @entries = entries
        @entries_loader = entries_loader
        @identity_resolver = identity_resolver
        @origin_absence_resolver = origin_absence_resolver
      end

      def repositories(filters: [])
        # Hive may also register local workspaces or repositories on another
        # host. They are valid registry rows, but cannot belong to PRDigest's
        # GitHub scope.
        available = entries.filter_map { |entry| repository_for(entry) }
                           .each_with_object({}) { |repo, dedup| dedup[repo.downcase] ||= repo }
                           .values
        raise Hive::ConfigError, "hive digest: no registered GitHub repositories" if available.empty?

        requested = normalize_filters(filters)
        return available.freeze if requested.empty?

        by_key = available.to_h { |repository| [ repository.downcase, repository ] }
        unknown = requested.reject { |repository| by_key.key?(repository.downcase) }
        unless unknown.empty?
          raise Hive::ConfigError,
                "hive digest: repositories are not registered: #{unknown.join(', ')}"
        end

        requested.map { |repository| by_key.fetch(repository.downcase) }.freeze
      end

      private

      def entries
        Array(@entries || @entries_loader.call)
      end

      def repository_for(entry)
        unless entry.is_a?(Hash)
          raise Hive::ConfigError, "hive digest: registered project entry is malformed"
        end

        identity = entry["repository_identity"].to_s.strip
        identity = @identity_resolver.call(entry["path"]) if identity.empty? && entry["path"].is_a?(String)
        return nil if non_github_identity?(identity)
        if identity.to_s.empty? &&
            entry["path"].is_a?(String) &&
            @origin_absence_resolver.call(entry["path"])
          return nil
        end

        match = identity.to_s.match(%r{\Agithub\.com/([^/]+)/([^/]+)\z}i)
        repository = match && "#{match[1]}/#{match[2]}"
        return repository if valid_repository?(repository)

        label = entry["name"].to_s.strip
        label = "(unnamed)" if label.empty?
        raise Hive::ConfigError,
              "hive digest: registered project #{label.inspect} does not resolve to github.com/owner/name"
      end

      def non_github_identity?(identity)
        value = identity.to_s
        return true if value.start_with?("local:")

        match = value.match(%r{\A([^/\s]+)/[^\s]+\z})
        match && !match[1].casecmp?("github.com")
      end

      def normalize_filters(filters)
        Array(filters).flatten.map(&:to_s).map(&:strip).each_with_object({}) do |repository, dedup|
          unless valid_repository?(repository)
            raise Hive::ConfigError,
                  "hive digest: --repo must use owner/name; got #{repository.inspect}"
          end
          dedup[repository.downcase] ||= repository
        end.values
      end

      def valid_repository?(repository)
        parts = repository.to_s.split("/", -1)
        parts.length == 2 &&
          parts.all? { |part| !part.empty? && !%w[. ..].include?(part) && part.match?(REPOSITORY_SEGMENT) }
      end
    end

    class Runner
      def initialize(date: nil, dry_run: false, repos: [], cfg: nil, env: ENV,
                     registry: Registry.new, binary_resolver: nil, token_resolver: nil,
                     process_runner: nil, env_loader: Hive::EnvFile, clock: -> { Time.now })
        @date = date
        @dry_run = dry_run
        @repos = repos
        @cfg = cfg
        @env = env
        @registry = registry
        @binary_resolver = binary_resolver || method(:resolve_binary)
        @token_resolver = token_resolver || method(:resolve_github_token)
        @process_runner = process_runner || lambda { |child_env, *argv|
          Open3.capture3(child_env, *argv)
        }
        @env_loader = env_loader
        @clock = clock
      end

      def call
        repositories = @registry.repositories(filters: @repos)
        cfg = @cfg || load_config
        @env_loader.load!(env: @env)
        github_token = @token_resolver.call(@env)
        raise Hive::ConfigError, "hive digest: GitHub authentication is unavailable" if github_token.to_s.empty?

        binary = @binary_resolver.call(@env)
        unless binary
          raise Hive::ConfigError,
                "hive digest: prdigest is not installed or executable (set PRDIGEST_BIN or install prdigest)"
        end

        with_config(cfg, repositories) do |config_path|
          argv = invocation(binary, config_path, repositories)
          child_env = {
            "HIVE_PRDIGEST_GITHUB_TOKEN" => github_token.to_s,
            # Open3 inherits unspecified variables. Explicitly delete the
            # Telegram credential in preview mode so dry-run cannot send even
            # when the parent Hive process has the token.
            "HIVE_TELEGRAM_BOT_TOKEN" =>
              (@dry_run ? nil : @env.fetch("HIVE_TELEGRAM_BOT_TOKEN"))
          }
          stdout, _stderr, status = @process_runner.call(
            child_env,
            *argv
          )
          payload = parse_payload(stdout)
          exit_code = status&.exitstatus
          exit_code = Hive::ExitCodes::SOFTWARE unless exit_code.is_a?(Integer)
          successful_status = %w[success dry_run].include?(payload.fetch("status"))
          if exit_code.zero? != successful_status
            raise Hive::InternalError,
                  "hive digest: prdigest result status contradicts its exit code"
          end
          result = Result.new(payload: payload, exit_code: exit_code, repositories: repositories, argv: argv.freeze)
          raise InvocationError, result unless result.success?

          result
        end
      end

      private

      def load_config
        {
          "digest" => Hive::Config.load_global_digest_block,
          "bot" => Hive::Config.load_global_bot
        }
      end

      def resolve_binary(env)
        configured = env["PRDIGEST_BIN"].to_s
        if configured.empty?
          return Hive::InvokedBinary.which("prdigest", env: env) || installed_prdigest_binary
        end

        if configured.include?(File::SEPARATOR)
          path = File.expand_path(configured)
          return path if File.file?(path) && File.executable?(path)
          return nil
        end
        Hive::InvokedBinary.which(configured, env: env)
      end

      def installed_prdigest_binary
        path = Gem.bin_path("prdigest", "prdigest", "~> 0.1.1")
        path if File.file?(path) && File.executable?(path)
      rescue Gem::Exception
        nil
      end

      def resolve_github_token(env)
        %w[GITHUB_TOKEN GH_TOKEN].each do |key|
          token = env[key].to_s
          return token unless token.empty?
        end

        out, _err, status = Hive::Gh.capture3(
          "gh", "auth", "token", "--hostname", "github.com",
          timeout_sec: 10,
          max_stdout_bytes: 4096
        )
        status.success? ? out.to_s.strip : ""
      rescue Hive::GhError
        ""
      end

      def with_config(cfg, repositories)
        Tempfile.create([ "hive-prdigest-", ".yml" ]) do |file|
          file.chmod(0o600)
          file.write(YAML.dump(config_payload(cfg, repositories)))
          file.flush
          file.fsync
          yield file.path
        end
      end

      def config_payload(cfg, repositories)
        bot = cfg.fetch("bot", {})
        chat_id = Array(bot["chat_id_allowlist"]).first
        chat_id = 1 if @dry_run && chat_id.nil?
        unless @dry_run
          chat_id = Hive::Config.telegram_chat_id!(bot)
          Hive::Config.telegram_bot_token!(env: @env)
        end

        state_root = File.join(Hive::Paths.state_home, "prdigest")
        {
          "timezone" => "Europe/London",
          "github" => {
            "token_env" => "HIVE_PRDIGEST_GITHUB_TOKEN",
            "repos" => repositories
          },
          "telegram" => {
            "token_env" => "HIVE_TELEGRAM_BOT_TOKEN",
            "chat_id_allowlist" => [ chat_id ],
            "chat_id" => chat_id
          },
          "digest" => {
            "line_stats" => true,
            "send_empty" => true
          },
          "state" => {
            "path" => File.join(state_root, "cursor.json"),
            "delivery_path" => File.join(state_root, "deliveries")
          }
        }
      end

      def invocation(binary, config_path, repositories)
        argv = [ binary, "run", "--config", config_path, "--json" ]
        date =
          if @date.to_s.empty?
            (Hive::LondonDate.today(now: @clock.call) - 1).iso8601
          else
            @date.to_s
          end
        argv.concat([ "--date", date ])
        argv << "--dry-run" if @dry_run
        repositories.each { |repository| argv.concat([ "--repo", repository ]) }
        argv
      end

      def parse_payload(stdout)
        payload = JSON.parse(stdout.to_s)
        valid = payload.is_a?(Hash) &&
                payload["schema"] == SCHEMA &&
                payload["schema_version"] == SCHEMA_VERSION &&
                payload["status"].is_a?(String) &&
                (payload["error"].nil? || payload["error"].is_a?(Hash))
        raise Hive::InternalError, "hive digest: prdigest returned an invalid result envelope" unless valid

        payload.freeze
      rescue JSON::ParserError
        raise Hive::InternalError, "hive digest: prdigest returned invalid JSON"
      end
    end

    module_function

    def run(date: nil, dry_run: false, repos: [], **options)
      Runner.new(date: date, dry_run: dry_run, repos: repos, **options).call
    end

    def failure_payload(kind:, message:, mode: "scheduled")
      {
        "schema" => SCHEMA,
        "schema_version" => SCHEMA_VERSION,
        "status" => "failure",
        "mode" => mode,
        "requested_days" => [],
        "settled_days" => [],
        "skipped_days" => [],
        "failed_date" => nil,
        "remaining_days" => [],
        "error" => {
          "kind" => kind.to_s,
          "message" => message.to_s
        },
        "chunks" => [],
        "delivery" => nil
      }
    end
  end
end
