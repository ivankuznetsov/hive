require "hive/workflow_package/configuration"
require "hive/workflow_package/runtime_policy"

module Hive
  module Commands
    class Workflow
      class ConfigurationResolver
        attr_reader :configuration

        def initialize(workflow:, resolution:, cfg:, runtime_metadata:, mapping_overrides: [], input_bindings: [],
                       previous: nil)
          @workflow = workflow
          @resolution = resolution
          @cfg = cfg
          @runtime_metadata = runtime_metadata
          @mapping_overrides = parse_mapping_overrides(mapping_overrides)
          @explicit_input_bindings = parse_input_bindings(input_bindings)
          @previous = previous
          @configuration = build
        end

        def mappings
          configuration.data.fetch("mappings").map do |slot, mapping|
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

        def inputs
          declared = Array(@runtime_metadata["optional_inputs"])
          declared.map do |entry|
            name = entry.fetch("name")
            binding = configuration.data.fetch("input_bindings")[name]
            {
              "name" => name,
              "authorized_slots" => entry.fetch("authorized_slots"),
              "binding" => binding,
              "available" => !!(binding && !ENV[binding].to_s.empty?)
            }
          end
        end

        def unbounded?
          Hive::WorkflowPackage::RuntimePolicy.workflow_escalation_reasons(@workflow).any?
        end

        def actor_policy_changed?
          return false unless @previous

          old = @previous.data.fetch("mappings").transform_values { |mapping| mapping["policy_fingerprint"] }
          current = configuration.data.fetch("mappings").transform_values { |mapping| mapping["policy_fingerprint"] }
          old != current
        end

        def input_bindings_changed?
          return false unless @previous

          declared = Array(@runtime_metadata["optional_inputs"]).map { |entry| entry.fetch("name") }
          previous = @previous.data.fetch("input_bindings").select { |name, _env| declared.include?(name) }
          current = configuration.data.fetch("input_bindings")
          previous != current
        end

        private

        def build
          prior_overrides = compatible_prior_mappings
          Hive::WorkflowPackage::Configuration.build(
            @workflow,
            generation: {
              "name" => @resolution.name,
              "source_commit" => @resolution.source_commit,
              "manifest_digest" => @resolution.manifest_digest
            },
            cfg: @cfg,
            overrides: prior_overrides.merge(@mapping_overrides),
            input_bindings: suggested_input_bindings
              .merge(prior_input_bindings)
              .merge(@explicit_input_bindings),
            runtime_metadata: @runtime_metadata
          )
        end

        def compatible_prior_mappings
          return {} unless @previous

          candidates = Hive::WorkflowPackage::Configuration.slots_for(@workflow).to_h { |slot| [ slot.id, slot ] }
          @previous.data.fetch("mappings").each_with_object({}) do |(id, mapping), out|
            slot = candidates[id]
            next unless slot
            unless slot.role == mapping["mapping_role"] && slot.contract == mapping["mapping_contract"]
              unless @mapping_overrides.key?(id)
                raise Hive::ConfigError,
                      "mapping contract changed for #{id}; provide an explicit mapping override to reconfirm"
              end
              next
            end
            next if @mapping_overrides.key?(id)

            current_profile = Hive::AgentProfiles.lookup(mapping.fetch("agent"), cfg: @cfg)
            unless mapping.fetch("profile_fingerprint") == Hive::WorkflowPackage::Configuration.profile_fingerprint(current_profile)
              raise Hive::ConfigError, "agent profile drifted for #{id}; provide an explicit mapping override to reconfirm"
            end
            out[id] = mapping.slice("agent", "model", "effort")
          end
        end

        def prior_input_bindings
          return {} unless @previous

          declared = Array(@runtime_metadata["optional_inputs"]).map { |entry| entry.fetch("name") }
          @previous.data.fetch("input_bindings").select { |name, _env| declared.include?(name) }
        end

        def parse_mapping_overrides(values)
          return values.transform_keys(&:to_s) if values.is_a?(Hash)

          Array(values).each_with_object({}) do |raw, out|
            slot, value = raw.to_s.split("=", 2)
            raise Hive::ConfigError, "mapping override must be SLOT=AGENT[,model=MODEL][,effort=EFFORT]" if value.to_s.empty?
            parts = value.split(",")
            mapping = { "agent" => parts.shift }
            parts.each do |part|
              key, child = part.split("=", 2)
              unless %w[model effort].include?(key) && !child.to_s.empty?
                raise Hive::ConfigError, "mapping override #{raw.inspect} is malformed"
              end
              mapping[key] = child
            end
            out[slot] = mapping
          end
        end

        def parse_input_bindings(values)
          return values.transform_keys(&:to_s) if values.is_a?(Hash)

          Array(values).each_with_object({}) do |raw, out|
            name, env_name = raw.to_s.split("=", 2)
            raise Hive::ConfigError, "input binding must be NAME=ENV_NAME" if env_name.to_s.empty?
            out[name] = env_name
          end
        end

        def suggested_input_bindings
          Array(@runtime_metadata["optional_inputs"]).each_with_object({}) do |entry, out|
            name = entry.fetch("name")
            out[name] = name unless ENV[name].to_s.empty?
          end
        end
      end
    end
  end
end
