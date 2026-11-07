# frozen_string_literal: true

require "hive"
require "hive/paths"
require "hive/atomic_file"
require "fileutils"
require "json"
require "securerandom"
require "uri"

module Hive
  # Client installation targets live outside project discovery and registries.
  # Bearers are kept in a separate private file and never returned in displays.
  class ConnectionContexts
    SCHEMA_VERSION = 1
    MAX_FILE_BYTES = 1024 * 1024
    LOCAL = { "name" => "local", "type" => "local" }.freeze

    attr_reader :contexts_path, :credentials_path

    def initialize(root: Hive::Paths.connection_contexts_home, verifier: nil)
      @root = root
      @contexts_path = File.join(root, "contexts.json")
      @credentials_path = File.join(root, "credentials.json")
      @lock_path = File.join(root, ".lock")
      @verifier = verifier
    end

    def resolve(name: nil)
      read do |config, _credentials|
        lookup(config, name || config.fetch("selected"))
      end
    end

    def list
      read do |config, _credentials|
        [ LOCAL.dup, *config.fetch("contexts").values.map(&:dup) ].map do |context|
          display(context).merge("selected" => context.fetch("name") == config.fetch("selected"))
        end.sort_by { |context| context.fetch("name") == "local" ? "" : context.fetch("name") }
      end
    end

    def show(name = nil, verify: true)
      context = resolve(name: name)
      return display(context) if context.fetch("type") == "local" || !verify

      display(context).merge(verify_metadata(context, credential(context)))
    end

    def credential(context)
      read do |_config, credentials|
        credentials.fetch("credentials").fetch(context.fetch("credential_ref")) do
          raise Hive::ConfigError, "missing credentials for context #{context.fetch('name')}; add the context again"
        end.dup
      end
    end

    def add(name, url:, token: nil, token_reader: nil)
      validate_name!(name)
      normalized_url = validate_url!(url)
      bearer = (token_reader ? token_reader.call : token).to_s.strip
      if bearer.empty? || bearer.bytesize > 4096 || bearer.match?(/\s/)
        raise Hive::UsageError, "provide one non-blank bearer using --token-stdin"
      end
      context = { "name" => name, "type" => "remote", "url" => normalized_url,
                  "credential_ref" => SecureRandom.hex(16) }
      metadata = verify_metadata(context, bearer)
      context["instance_id"] = metadata.fetch("instance_id")
      write do |config, credentials|
        credentials.fetch("credentials")[context.fetch("credential_ref")] = bearer
        config.fetch("contexts")[name] = context
      end
      display(context).merge(metadata)
    end

    def use(name)
      context = resolve(name: name)
      bearer = credential(context) unless context.fetch("type") == "local"
      metadata = bearer ? verify_metadata(context, bearer) : {}
      write do |config, credentials|
        current = lookup(config, name)
        if current != context || (bearer && credentials.fetch("credentials")[current.fetch("credential_ref")] != bearer)
          raise Hive::ConfigError, "context changed while being verified; retry context use"
        end
        config["selected"] = name
      end
      display(context).merge(metadata)
    end

    private

    def validate_name!(name)
      unless name.is_a?(String) && name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/) && name != "local"
        raise Hive::UsageError, "context name must contain letters, digits, dots, underscores or hyphens; local is reserved"
      end
    end

    def validate_url!(value)
      uri = URI.parse(value.to_s)
      unless uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty? && !uri.userinfo && !uri.query && !uri.fragment
        raise URI::InvalidURIError
      end
      uri.to_s.delete_suffix("/")
    rescue URI::InvalidURIError, ArgumentError
      raise Hive::UsageError, "context URL must use HTTPS without userinfo, query or fragment"
    end

    def verify_metadata(context, bearer)
      raise Hive::ConfigError, "remote context verification is unavailable" unless @verifier

      metadata = invoke_verifier(context, bearer)
      instance = metadata.fetch("instance_id")
      version = metadata.fetch("api_version")
      unless instance.is_a?(String) && !instance.empty? && version == "v1"
        raise Hive::ConfigError, "unsupported remote API version; upgrade Hive or select a compatible server"
      end
      if context["instance_id"] && context.fetch("instance_id") != instance
        raise Hive::ConfigError, "remote installation identity changed; add the context again after verifying the server"
      end
      token = metadata.fetch("token", {})
      { "instance_id" => instance, "api_version" => version,
        "authority" => token.slice("id", "scopes", "projects", "all_projects", "expires_at") }
    rescue Hive::Error
      raise
    rescue StandardError
      raise Hive::ConfigError, "could not verify remote context; check the server and credentials"
    end

    def invoke_verifier(context, bearer)
      @verifier.call(context.dup.freeze, bearer)
    rescue StandardError => error
      # This one transport error constructs its diagnostic entirely from a
      # fixed message and validated API base paths. Arbitrary verifier errors
      # can include credentials and remain hidden.
      if defined?(Hive::Remote::Client::UnsupportedVersion) && error.is_a?(Hive::Remote::Client::UnsupportedVersion)
        raise
      end
      # HTTP library and fixture exceptions can include request headers.
      # Only the boundary's own fixed diagnostics may reach CLI output.
      raise Hive::ConfigError, "could not verify remote context; check the server and credentials"
    end

    def display(context)
      context.reject { |key, _| key == "credential_ref" }.merge(
        context.fetch("type") == "local" ? { "authority" => { "kind" => "unrestricted-local-operator" } } : {}
      )
    end

    def lookup(config, name)
      return LOCAL.dup if name == "local"

      config.fetch("contexts").fetch(name) do
        raise Hive::UsageError, "unknown context; use hive context list"
      end.dup
    end

    def empty_config = { "schema_version" => SCHEMA_VERSION, "selected" => "local", "contexts" => {} }
    def empty_credentials = { "schema_version" => SCHEMA_VERSION, "credentials" => {} }

    def read
      return yield(empty_config, empty_credentials) unless Dir.exist?(@root)

      with_lock(File::LOCK_SH) do
        config, credentials = load_config, load_credentials
        verify_references!(config, credentials)
        yield(config, credentials)
      end
    end

    def write
      FileUtils.mkdir_p(@root, mode: 0o700)
      File.chmod(0o700, @root)
      with_lock(File::LOCK_EX) do
        config = load_config
        credentials = load_credentials
        verify_references!(config, credentials)
        result = yield(config, credentials)
        # Store credentials first: a crash can leave an unused credential,
        # while the reverse order could select a target with missing authority.
        Hive::AtomicFile.write(@credentials_path, JSON.generate(credentials), mode: 0o600)
        Hive::AtomicFile.write(@contexts_path, JSON.generate(config), mode: 0o600)
        references = config.fetch("contexts").values.map { |context| context.fetch("credential_ref") }
        cleaned = credentials.fetch("credentials").slice(*references)
        if cleaned != credentials.fetch("credentials")
          Hive::AtomicFile.write(@credentials_path, JSON.generate(credentials.merge("credentials" => cleaned)), mode: 0o600)
        end
        Hive::AtomicFile.fsync_directory(@root)
        result
      end
    end

    def with_lock(mode)
      File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.chmod(0o600)
        lock.flock(mode)
        yield
      ensure
        lock.flock(File::LOCK_UN) if lock
      end
    end

    def load_document(path, default)
      return default unless File.exist?(path)
      raise Hive::ConfigError, "context configuration is too large" if File.size(path) > MAX_FILE_BYTES

      document = JSON.parse(File.read(path))
      version = document.is_a?(Hash) && document["schema_version"]
      if version.is_a?(Integer) && version > SCHEMA_VERSION
        raise Hive::ConfigError, "context configuration uses a newer schema; upgrade Hive"
      end
      raise Hive::ConfigError, "invalid context configuration schema" unless version == SCHEMA_VERSION

      document
    rescue JSON::ParserError, EncodingError
      raise Hive::ConfigError, "invalid context configuration; repair it before continuing"
    end

    def load_config
      document = load_document(@contexts_path, empty_config)
      contexts = document["contexts"]
      valid = contexts.is_a?(Hash) && document["selected"].is_a?(String)
      valid &&= contexts.all? do |name, context|
        context.is_a?(Hash) && name.is_a?(String) && name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/) &&
          name == context["name"] && name != "local" &&
          context["type"] == "remote" && context["url"].is_a?(String) &&
          valid_stored_url?(context["url"]) && context["credential_ref"].is_a?(String) &&
          context["instance_id"].is_a?(String) && !context["instance_id"].empty?
      end
      valid &&= document["selected"] == "local" || contexts.key?(document["selected"])
      raise Hive::ConfigError, "invalid context configuration; repair it before continuing" unless valid

      document
    end

    def valid_stored_url?(url)
      validate_url!(url)
      true
    rescue Hive::UsageError
      false
    end

    def verify_references!(config, credentials)
      return if config.fetch("contexts").values.all? do |context|
        credentials.fetch("credentials").key?(context.fetch("credential_ref"))
      end

      raise Hive::ConfigError, "missing context credentials; add the context again after repairing the configuration"
    end

    def load_credentials
      document = load_document(@credentials_path, empty_credentials)
      credentials = document["credentials"]
      unless credentials.is_a?(Hash) && credentials.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
        raise Hive::ConfigError, "invalid credential configuration; repair it before continuing"
      end
      document
    end
  end
end
