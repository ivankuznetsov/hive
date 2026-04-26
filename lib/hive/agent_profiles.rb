require "hive/agent_profile"

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

        return entry if cfg.nil?

        overrides = cfg.dig("agents", name.to_s)
        return entry if overrides.nil? || overrides.empty?

        entry.with_overrides(overrides)
      end

      def registered?(name)
        @mutex.synchronize { @profiles.key?(name.to_sym) }
      end

      def registered_names
        @mutex.synchronize { @profiles.keys }
      end

      # Test helper: clear the registry. Used by per-test setup that wants
      # a clean slate; production code never calls this.
      def reset_for_tests!
        @mutex.synchronize { @profiles.clear }
      end
    end
  end
end

# Auto-register the three v1 built-in profiles. Each file under
# lib/hive/agent_profiles/ requires this file and calls register at load
# time, so consumers only need `require "hive/agent_profiles"` to get the
# full v1 set.
require "hive/agent_profiles/claude"
require "hive/agent_profiles/codex"
require "hive/agent_profiles/pi"
