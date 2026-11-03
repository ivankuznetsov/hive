require "digest"
require "hive/task_capabilities/catalog"
require "hive/secret_patterns"

module Hive
  module TaskCapabilities
    # The executable selection is independent of the agent-authored plan.md.
    class Plan
      SCHEMA_VERSION = 1
      KEYS = %w[schema_version version task source configuration_digest catalog_digest definitions inputs choices bindings policy approvals waivers recommendations blockers].freeze
      REQUIRED = %w[schema_version version task source configuration_digest catalog_digest definitions inputs choices bindings policy approvals waivers recommendations blockers].freeze
      DIGEST = /\A[0-9a-f]{64}\z/
      attr_reader :data

      def initialize(value)
        @data = self.class.redact(Hive::WorkflowPackage::CanonicalJSON.normalize(value))
        unless data.is_a?(Hash) && (data.keys - KEYS).empty? && (REQUIRED - data.keys).empty? &&
            data["schema_version"] == SCHEMA_VERSION && data["version"].is_a?(Integer) && data["version"].positive?
          raise Hive::ConfigError, "invalid task execution-plan schema or version"
        end
        unless data["task"].is_a?(Hash) && data["task"].keys.sort == %w[id slug workflow] &&
            data["task"]["slug"].is_a?(String) && !data["task"]["slug"].empty?
          raise Hive::ConfigError, "execution plan requires stable task identity"
        end
        %w[source inputs choices policy].each do |key|
          raise Hive::ConfigError, "execution-plan #{key} must be a map" unless data[key].is_a?(Hash)
        end
        %w[definitions bindings approvals waivers recommendations blockers].each do |key|
          raise Hive::ConfigError, "execution-plan #{key} must be an array" unless data[key].is_a?(Array)
        end
        %w[configuration_digest catalog_digest].each do |key|
          raise Hive::ConfigError, "execution-plan #{key} must be a SHA-256 digest" unless DIGEST.match?(data[key].to_s)
        end
        unless data["inputs"].values.all? { |choice| %w[automatic on off].include?(choice) }
          raise Hive::ConfigError, "execution-plan inputs must be automatic, on or off"
        end
        data.fetch("definitions").each { |entry| validate_definition!(entry) }
        data.fetch("bindings").each do |binding|
          unless binding.is_a?(Hash) && data.fetch("definitions").any? { |entry| entry.fetch("id") == binding["id"] }
            raise Hive::ConfigError, "execution-plan binding must reference a pinned definition"
          end
        end
        Definition.deep_freeze(data)
        freeze
      end

      def self.minimal(task_identity:, catalog:, source:, policy:, configuration_digest: nil)
        definitions = catalog.definitions.map do |definition|
          entry = definition.to_h.dup
          entry["instruction_content"] = File.binread(definition.instruction_path) if definition.instruction_path
          entry
        end
        new(
          "schema_version" => SCHEMA_VERSION, "version" => 1, "task" => task_identity,
          "source" => source, "configuration_digest" => configuration_digest ||
            ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(policy)),
          "catalog_digest" => catalog.digest, "definitions" => definitions,
          "inputs" => definitions.to_h { |entry| [ entry.fetch("id"), "automatic" ] },
          "choices" => {}, "bindings" => [], "policy" => policy,
          "approvals" => [], "waivers" => [], "recommendations" => [], "blockers" => []
        )
      end

      def version = data.fetch("version")
      def to_h = data
      def bytes = Hive::WorkflowPackage::CanonicalJSON.generate(data)
      def digest = ::Digest::SHA256.hexdigest(bytes)
      def adoption
        { "schema_version" => SCHEMA_VERSION, "adopted" => true,
          "initial_plan_version" => 1, "initial_plan_digest" => digest }
      end

      def incompatible_bindings(catalog, previous_workflow: nil)
        data.fetch("bindings").filter_map do |binding|
          pinned = data.fetch("definitions").find { |entry| entry.fetch("id") == binding.fetch("id") }
          candidate = catalog.definitions.find { |entry| entry.id == binding.fetch("id") }
          changed = !candidate || candidate.to_h != pinned.reject { |key, _| key == "instruction_content" }
          if !changed && previous_workflow && !pinned.key?("actor")
            changed = pinned.fetch("stages").any? do |name|
              before = previous_workflow.stage_named(name)
              after = catalog.workflow.stage_named(name)
              !before || !after || stage_envelope(before) != stage_envelope(after)
            end
          end
          binding.fetch("id") if changed
        end
      end

      def self.redact(value)
        case value
        when Hash
          value.to_h do |key, child|
            if key == "targets"
              Definition.targets(child, label: "execution plan")
              unless child.all? { |target| Hive::SecretPatterns.redact(target) == target }
                raise Hive::ConfigError, "execution-plan targets must be non-secret references"
              end
            end
            [ key, redact(child) ]
          end
        when Array then value.map { |child| redact(child) }
        when String then Hive::SecretPatterns.redact(value)
        else value
        end
      end

      private

      def stage_envelope(stage)
        result = stage.to_h.slice(:index, :agent, :model, :effort, :skill, :permissions, :budget_usd, :timeout_sec)
        result[:instruction_digest] = stage.instruction && ::Digest::SHA256.file(stage.instruction).hexdigest
        result
      end

      def validate_definition!(entry)
        unless entry.is_a?(Hash) && entry["id"].is_a?(String) && Definition::ID.match?(entry["id"])
          raise Hive::ConfigError, "execution-plan definition requires a capability ID"
        end
        return unless entry.key?("instruction")

        content = entry["instruction_content"]
        unless content.is_a?(String) && ::Digest::SHA256.hexdigest(content) == entry["instruction_digest"]
          raise Hive::ConfigError, "execution-plan instruction must embed its immutable content"
        end
      end
    end
  end
end
