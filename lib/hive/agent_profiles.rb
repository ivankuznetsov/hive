require "hive/agent_profile"
require "hive/agent_support"

module Hive
  # Registry for the AgentProfile instances hive ships and any custom ones
  # a project registers. Looked up by symbolic name from per-role config
  # (e.g., review.triage.agent: claude → AgentProfiles.lookup(:claude)).
  module AgentProfiles
    class UnknownAgent < Hive::ConfigError; end

    @profiles = {}
    @mutex = Mutex.new

    class << self
      # Register a profile under a name. Re-registering replaces the old
      # entry (lets tests swap stubs in for a profile name).
      def register(name, profile)
        unless profile.is_a?(Hive::AgentProfile)
          raise ArgumentError, "register expected Hive::AgentProfile, got #{profile.class}"
        end

        @mutex.synchronize do
          @profiles[name.to_sym] = profile
        end
      end

      # Resolve a profile by name, optionally overlaying
      # `cfg.dig("agents", name)` overrides from the merged project
      # config. Without `cfg:` the registry-stored profile is returned
      # unchanged (preserving the call sites that don't have cfg in
      # scope, like Hive::Agent's legacy class-method shims). With
      # `cfg:` set, an `agents.<name>.<key>` block is overlaid via
      # AgentProfile#with_overrides — `bin`, `env_override`, and
      # `min_version` are the documented keys; an unknown key raises
      # Hive::ConfigError loudly.
      def lookup(name, cfg: nil)
        sym = name.to_sym
        entry = @mutex.synchronize { @profiles[sym] }
        raise UnknownAgent, "unknown agent profile: #{name.inspect} (registered: #{registered_names.inspect})" if entry.nil?

        support = Hive::AgentSupport.for(entry)
        if support&.respond_to?(:configuration) && !entry.support_configuration
          entry = entry.with_support_configuration(support.configuration)
        end

        return entry if cfg.nil?

        overrides = cfg.dig("agents", name.to_s)
        return entry if overrides.nil? || overrides.empty?

        entry.with_overrides(resolve_project_paths(entry, overrides, cfg))
      rescue ArgumentError => e
        raise Hive::ConfigError,
              "agents.#{name} configuration is invalid: #{e.message}", cause: e
      end

      def registered?(name)
        @mutex.synchronize { @profiles.key?(name.to_sym) }
      end

      def registered_names
        @mutex.synchronize { @profiles.keys }
      end

      def support_for(profile) = Hive::AgentSupport.for(profile)

      def grok_auth_path(home: nil)
        AgentCliRuntime::Profiles.grok_auth_path(home:, env: ENV)
      end

      def logged_in?(name, home: nil)
        # Probe the specific credential artifact each CLI writes on a
        # successful login, NOT merely a non-empty config dir: both claude
        # and codex create ~/.claude / ~/.codex (settings, cache, history)
        # the first time they run, *before* any token exists, so a dir check
        # reports a green "Logged in" on a box that has no credential.
        support = Hive::AgentSupport.for(name)
        return credential_present?(support.credential_path(home: home || Dir.home)) if support

        case name.to_sym
        when :claude
          credential_present?(File.join(home || Dir.home, ".claude", ".credentials.json"))
        when :codex
          credential_present?(File.join(home || Dir.home, ".codex", "auth.json"))
        when :grok
          credential_present?(grok_auth_path(home:))
        else
          false
        end
      rescue SystemCallError, ArgumentError
        false
      end

      # True iff `path` is a regular file holding more than an empty JSON
      # object — i.e. an actual credential, not a freshly-created `{}` stub.
      def credential_present?(path)
        File.file?(path) && !File.read(path).strip.match?(/\A(?:|\{\s*\})\z/m)
      end

      # Test helper: clear the registry. Used by per-test setup that wants
      # a clean slate; production code never calls this.
      def reset_for_tests!
        @mutex.synchronize { @profiles.clear }
      end

      private

      def resolve_project_paths(profile, overrides, cfg)
        return overrides unless overrides.is_a?(Hash)

        configuration = profile.support_configuration
        return overrides unless configuration&.respond_to?(:resolve_project_paths)

        configuration.resolve_project_paths(
          overrides, root: cfg["project_root"].to_s
        )
      end
    end
  end
end

# Auto-register the built-in profiles. Each file under
# lib/hive/agent_profiles/ requires this file and calls register at load
# time, so consumers only need `require "hive/agent_profiles"` to get the
# full v1 set.
require "hive/agent_profiles/claude"
require "hive/agent_profiles/codex"
require "hive/agent_profiles/pi"
require "hive/agent_profiles/grok"
require "hive/agent_profiles/opencode"
require "hive/agent_profiles/error_normalizers"
require "hive/agent_profiles/launch_bindings"
