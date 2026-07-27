require "digest"
require "json"
require "hive/agent_profiles"
require "hive/permission_scope"
require "hive/stringify_keys"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/input_name"
require "hive/workflow_package/manifest"
require "hive/workflow_package/registry_client"
require "hive/workflows/descriptor_parser"

module Hive
  module WorkflowPackage
    # Immutable operator-owned execution identity for one immutable package
    # generation. Package descriptors describe work; this snapshot selects the
    # agent/model/effort used by every stable executable slot.
    class Configuration
      SCHEMA_VERSION = 1
      SHA256 = Manifest::SHA256
      SLOT_ID = /\Astages\.[a-z0-9][a-z0-9_-]*(?:\.reviewers\.[a-z0-9][a-z0-9_-]*|\.revise)?\z/
      ROLES = Hive::Workflow::MAPPING_ROLES
      MAPPING_RECOMMENDATION_EFFORTS = %w[low medium high].freeze

      Slot = Data.define(:id, :role, :contract, :actor, :permissions, :authorized_inputs)

      attr_reader :data, :bytes, :digest

      def self.build(workflow, generation:, cfg: {}, overrides: {}, input_bindings: {}, runtime_metadata: {})
        slots = slots_for(workflow, runtime_metadata: runtime_metadata)
        normalized_overrides = stringify_hash(overrides)
        unknown = normalized_overrides.keys - slots.map(&:id)
        raise Hive::ConfigError, "workflow mapping contains unknown slot(s): #{unknown.sort.join(', ')}" unless unknown.empty?

        reviewer_defaults = reviewer_agents(cfg)
        recommendations = mapping_recommendations(runtime_metadata)
        mappings = slots.each_with_index.to_h do |slot, index|
          override = normalize_override(normalized_overrides.fetch(slot.id, {}), slot.id)
          recommendation = recommendations.fetch(slot.id, {})
          suggested = suggested_agent(slot.role, cfg, reviewer_defaults, index)
          suggested = policy_compatible_suggestion(slot, suggested, cfg) unless override.key?("agent")
          agent = override.fetch("agent", suggested).to_s
          profile = Hive::AgentProfiles.lookup(agent, cfg: cfg)
          model = override.key?("model") ? normalize_optional(override["model"]) : suggested_model(slot.role, cfg, profile)
          effort = resolved_effort(override, recommendation, slot.role, cfg, profile)
          validate_pin_support!(profile, slot.id, model: model, effort: effort)
          [ slot.id, {
            "mapping_role" => slot.role,
            "mapping_contract" => slot.contract,
            "agent" => profile.name.to_s,
            "model" => model,
            "effort" => effort,
            "profile_fingerprint" => profile_fingerprint(profile),
            "policy_fingerprint" => policy_fingerprint(slot)
          } ]
        end

        available_inputs = Array(runtime_metadata["optional_inputs"]).to_h { |entry| [ entry.fetch("name"), entry ] }
        bindings = stringify_hash(input_bindings).each_with_object({}) do |(name, env_name), out|
          raise Hive::ConfigError, "workflow input binding #{name.inspect} is undeclared" unless available_inputs.key?(name)
          env = env_name.to_s.strip
          unless InputName::PORTABLE.match?(env)
            raise Hive::ConfigError, "workflow input #{name.inspect} must bind to an environment variable name"
          end
          out[name] = env
        end

        data = {
          "schema_version" => SCHEMA_VERSION,
          "generation" => stringify_hash(generation),
          "mappings" => mappings.sort.to_h,
          "input_bindings" => bindings.sort.to_h
        }
        new(data)
      end

      def self.load(bytes)
        data = JSON.parse(bytes)
        canonical = CanonicalJSON.generate(data)
        raise Hive::ConfigError, "managed workflow configuration is not canonical JSON" unless bytes == canonical

        new(data)
      rescue JSON::ParserError, EncodingError
        raise Hive::ConfigError, "managed workflow configuration is malformed"
      end

      def initialize(data)
        @data = Hive::StringifyKeys.call(data)
        validate!
        @bytes = CanonicalJSON.generate(@data).freeze
        @digest = ::Digest::SHA256.hexdigest(@bytes).freeze
        deep_freeze(@data)
        freeze
      end

      def apply(workflow, cfg: {}, verify_profiles: true)
        specs = self.class.slots_for(workflow)
        expected = specs.map(&:id).sort
        actual = data.fetch("mappings").keys.sort
        raise Hive::ConfigError, "managed workflow configuration slots do not match descriptor" unless actual == expected
        specs_by_id = specs.to_h { |slot| [ slot.id, slot ] }

        stages = workflow.stages.map do |stage|
          next stage unless [ :agent, :council ].include?(stage.kind)

          stage_mapping = mapping_for(specs_by_id.fetch("stages.#{stage.name}"), cfg, verify_profiles)
          reviewers = Array(stage.reviewers).map do |reviewer|
            mapping = mapping_for(
              specs_by_id.fetch("stages.#{stage.name}.reviewers.#{reviewer.name}"),
              cfg, verify_profiles
            )
            reviewer.with(agent: mapping.fetch("agent"), model: mapping["model"], effort: mapping["effort"])
          end
          council = stage.council
          if council&.revise
            mapping = mapping_for(specs_by_id.fetch("stages.#{stage.name}.revise"), cfg, verify_profiles)
            council = council.with(revise: council.revise.with(
              agent: mapping.fetch("agent"), model: mapping["model"], effort: mapping["effort"]
            ))
          end
          stage.with(
            agent: stage_mapping.fetch("agent"), model: stage_mapping["model"], effort: stage_mapping["effort"],
            reviewers: reviewers.empty? ? stage.reviewers : reviewers.freeze, council: council
          )
        end
        Hive::Workflow.new(
          id: workflow.id,
          stages: stages,
          archive_visibility_retention_days: workflow.archive_visibility_retention_days
        )
      end

      def input_environment_for(slot_id, runtime_metadata:, environment: ENV)
        authorized = Array(runtime_metadata["optional_inputs"]).select do |entry|
          Array(entry["authorized_slots"]).include?(slot_id)
        end
        authorized.each_with_object({}) do |entry, out|
          name = entry.fetch("name")
          env_name = data.fetch("input_bindings")[name]
          next unless env_name
          value = environment[env_name]
          out[name] = value if value && !value.empty?
        end
      end

      def input_status_for(slot_id, runtime_metadata:, environment: ENV)
        Array(runtime_metadata["optional_inputs"]).filter_map do |entry|
          next unless Array(entry["authorized_slots"]).include?(slot_id)

          input_status(entry, environment)
        end
      end

      def mapping_rows
        data.fetch("mappings").map do |slot, mapping|
          {
            "slot" => slot,
            "mapping_role" => mapping.fetch("mapping_role"),
            "mapping_contract" => mapping.fetch("mapping_contract"),
            "agent" => mapping.fetch("agent"),
            "model" => mapping["model"],
            "effort" => mapping["effort"],
            "profile_fingerprint" => mapping.fetch("profile_fingerprint"),
            "policy_fingerprint" => mapping.fetch("policy_fingerprint")
          }
        end
      end

      def input_rows(runtime_metadata:, environment: ENV)
        Array(runtime_metadata["optional_inputs"]).map do |entry|
          input_status(entry, environment).tap do |row|
            row["authorized_slots"] = entry.fetch("authorized_slots")
          end
        end
      end

      def self.slots_for(workflow, runtime_metadata: {})
        authorized = Hash.new { |hash, key| hash[key] = [] }
        Array(runtime_metadata["optional_inputs"]).each do |entry|
          Array(entry["authorized_slots"]).each { |slot| authorized[slot] << entry.fetch("name") }
        end
        workflow.executable_slots.map do |executable|
          slot(executable, authorized: authorized)
        end
      end

      def self.profile_fingerprint(profile)
        values = {
          "name" => profile.name.to_s,
          "bin" => profile.bin.to_s,
          "launcher_identity" => profile.launcher_identity.to_s,
          "prompt_style" => profile.prompt_style.to_s,
          "headless_supported" => !!profile.headless_supported,
          "permission_skip_flag" => profile.permission_skip_flag,
          "workspace_write_flags" => Array(profile.workspace_write_flags),
          "policy_capabilities" => Array(profile.policy_capabilities).map(&:to_s).sort,
          "model_pinning" => !profile.model_argument_builder.nil?,
          "effort_pinning" => !profile.effort_argument_builder.nil?
        }
        ::Digest::SHA256.hexdigest(CanonicalJSON.generate(values))
      end

      def self.validate_pin_support!(profile, slot_id, model:, effort:)
        if model && !profile.model_argument_builder
          raise Hive::ConfigError,
                "workflow mapping #{slot_id} agent #{profile.name} cannot pin model"
        end
        if effort && (!profile.effort_argument_builder || !profile.model_argument_builder)
          raise Hive::ConfigError,
                "workflow mapping #{slot_id} agent #{profile.name} cannot pin effort"
        end
      end

      def self.legacy_overrides(workflow)
        slots_for(workflow).each_with_object({}) do |slot, out|
          actor = slot.actor
          mapping = {}
          mapping["agent"] = actor.agent.to_s unless actor.agent.to_s.empty?
          mapping["model"] = actor.model.to_s unless actor.model.to_s.empty?
          mapping["effort"] = actor.effort.to_s unless actor.effort.to_s.empty?
          out[slot.id] = mapping unless mapping.empty?
        end
      end

      class << self
        private

        def slot(executable, authorized:)
          actor = executable.actor
          role = actor.respond_to?(:mapping_role) && actor.mapping_role || executable.default_role
          contract = actor.respond_to?(:mapping_contract) && actor.mapping_contract || "legacy-v1"
          Slot.new(id: executable.id, role: role, contract: contract, actor: actor,
                   permissions: actor.respond_to?(:permissions) ? actor.permissions : nil,
                   authorized_inputs: authorized[executable.id].sort).freeze
        end

        def suggested_agent(role, cfg, reviewer_defaults, index)
          value = case role
          when "planning" then cfg.dig("plan", "agent")
          when "development" then cfg.dig("execute", "agent")
          when "reviewer" then reviewer_defaults[index % reviewer_defaults.length]
          end
          value.to_s.empty? ? "claude" : value.to_s
        end

        # Non-yolo actor policies currently require Claude's native tool
        # scoping. Keep operator-supplied mappings exact (runtime admission
        # rejects an incompatible explicit choice), but never suggest a
        # project default that Hive already knows it cannot launch.
        def policy_compatible_suggestion(slot, suggested, cfg)
          preset = Hive::PermissionScope.parse_spec(slot.permissions, stage: slot.id).fetch("preset")
          profile = Hive::AgentProfiles.lookup(suggested, cfg: cfg)
          return suggested if preset == Hive::PermissionScope::YOLO || profile.name == :claude

          "claude"
        end

        def reviewer_agents(cfg)
          names = Array(cfg.dig("review", "reviewers")).filter_map do |entry|
            entry["agent"] if entry.is_a?(Hash)
          end
          names = [ cfg.dig("review", "triage", "agent") || "claude" ] if names.empty?
          names
        end

        def suggested_model(role, cfg, profile)
          return nil unless profile.model_argument_builder

          value = cfg.dig(role == "planning" ? "plan" : "execute", "model")
          value ||= cfg.dig("claude", "model") if profile.name == :claude
          normalize_optional(value)
        end

        def suggested_effort(role, cfg, profile)
          return nil unless profile.effort_argument_builder

          value = cfg.dig(role == "planning" ? "plan" : "execute", "effort")
          value ||= cfg.dig("claude", "effort") if profile.name == :claude
          normalize_optional(value)
        end

        def resolved_effort(override, recommendation, role, cfg, profile)
          return normalize_optional(override["effort"]) if override.key?("effort")
          unless recommendation.key?("effort")
            return suggested_effort(role, cfg, profile)
          end
          return nil unless profile.effort_argument_builder && profile.model_argument_builder

          normalize_optional(recommendation["effort"])
        end

        def mapping_recommendations(runtime_metadata)
          Array(runtime_metadata["mapping_recommendations"]).to_h do |entry|
            [ entry.fetch("slot"), entry ]
          end
        end

        def normalize_override(value, slot)
          hash = stringify_hash(value)
          unknown = hash.keys - %w[agent model effort]
          raise Hive::ConfigError, "workflow mapping #{slot} has unsupported fields" unless unknown.empty?
          hash
        end

        def normalize_optional(value)
          string = value.to_s.strip
          return nil if string.empty? || %w[default inherit].include?(string)
          string
        end

        def policy_fingerprint(slot)
          ::Digest::SHA256.hexdigest(CanonicalJSON.generate(
            "permissions" => slot.permissions,
            "authorized_inputs" => slot.authorized_inputs
          ))
        end

        def stringify_hash(value)
          raise Hive::ConfigError, "workflow configuration value must be a map" unless value.is_a?(Hash)
          value.to_h { |key, child| [ key.to_s, child ] }
        end
      end

      private

      def input_status(entry, environment)
        name = entry.fetch("name")
        binding = data.fetch("input_bindings")[name]
        {
          "name" => name,
          "binding" => binding,
          "available" => !!(binding && !environment[binding].to_s.empty?)
        }
      end

      def mapping_for(slot, cfg, verify_profiles)
        mapping = data.fetch("mappings").fetch(slot.id)
        unless mapping.fetch("mapping_role") == slot.role &&
               mapping.fetch("mapping_contract") == slot.contract
          raise Hive::ConfigError, "managed workflow configuration contract drifted for #{slot.id}"
        end
        profile = Hive::AgentProfiles.lookup(mapping.fetch("agent"), cfg: cfg)
        self.class.validate_pin_support!(
          profile, slot.id, model: mapping["model"], effort: mapping["effort"]
        )
        if verify_profiles
          unless mapping.fetch("profile_fingerprint") == self.class.profile_fingerprint(profile)
            raise Hive::ConfigError,
                  "managed workflow agent profile drifted for #{slot.id}; reinstall or update the workflow mapping"
          end
        end
        mapping
      end

      def validate!
        unless data.keys.sort == %w[generation input_bindings mappings schema_version] && data["schema_version"] == SCHEMA_VERSION
          raise Hive::ConfigError, "managed workflow configuration has an unsupported shape"
        end
        generation = data["generation"]
        required_generation = %w[manifest_digest name source_commit]
        unless generation.is_a?(Hash) && generation.keys.sort == required_generation &&
               generation["name"].to_s.match?(Hive::Workflows::DescriptorParser::SAFE_SLUG) &&
               generation["source_commit"].to_s.match?(Hive::WorkflowPackage::RegistryClient::FULL_SHA) &&
               generation["manifest_digest"].to_s.match?(SHA256)
          raise Hive::ConfigError, "managed workflow configuration generation is malformed"
        end
        unless data["mappings"].is_a?(Hash) && !data["mappings"].empty? && data["input_bindings"].is_a?(Hash)
          raise Hive::ConfigError, "managed workflow configuration mappings are malformed"
        end
        data["mappings"].each do |id, mapping|
          keys = %w[agent effort mapping_contract mapping_role model policy_fingerprint profile_fingerprint]
          unless SLOT_ID.match?(id) && mapping.is_a?(Hash) && mapping.keys.sort == keys &&
                 ROLES.include?(mapping["mapping_role"]) && !mapping["mapping_contract"].to_s.empty? &&
                 Hive::AgentProfiles.registered?(mapping["agent"]) &&
                 SHA256.match?(mapping["profile_fingerprint"].to_s) && SHA256.match?(mapping["policy_fingerprint"].to_s)
            raise Hive::ConfigError, "managed workflow configuration mapping #{id.inspect} is malformed"
          end
        end
      end

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |child| deep_freeze(child) }.freeze
        when Array then value.each { |child| deep_freeze(child) }.freeze
        else value.freeze
        end
      end
    end
  end
end
