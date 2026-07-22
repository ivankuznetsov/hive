require "hive/conditions/registry"
require "hive/stringify_keys"

module Hive
  module Conditions
    class InvalidPolicy < Hive::Error; end

    GateRule = Data.define(
      :version, :transition, :required, :inhibitors, :options, :authoritative_capable
    ) do
      def to_h
        {
          "version" => version,
          "transition" => transition,
          "required" => required,
          "inhibitors" => inhibitors,
          "options" => options,
          "authoritative_capable" => authoritative_capable
        }
      end
    end

    class Policy
      VERSION = 1
      OPTION_KEYS = %w[no_commit_success].freeze

      def self.default
        @default ||= begin
          policy = new
          policy.add(
            transition: "execute_to_open_pr",
            required: %w[AgentHealthy ChangesPresent], inhibitors: [ "AwaitingHuman" ],
            options: { "no_commit_success" => true }, authoritative_capable: true
          )
          policy.add(transition: "open_pr_to_review", required: [ "BranchPushed" ])
          policy.add(transition: "review_active", required: [ "BabysitterActive" ])
          policy.add(transition: "artifacts_to_finalize", required: [ "ArtifactCurrent" ])
          policy.add(transition: "finalize_to_archive", required: [ "Merged" ])
          policy.freeze
        end
      end

      def self.rule_from_descriptor(value, registry: Registry.default)
        data = Hive::StringifyKeys.call(value)
        unless data.is_a?(Hash)
          raise InvalidPolicy, "conditions must be an object"
        end
        allowed = %w[version transition required inhibitors options]
        unknown = data.keys - allowed
        raise InvalidPolicy, "conditions has unknown keys: #{unknown.join(', ')}" unless unknown.empty?
        version = data.fetch("version", VERSION)
        raise InvalidPolicy, "conditions version must be #{VERSION}" unless version == VERSION

        new(registry: registry).build_rule(
          transition: data.fetch("transition"),
          required: data.fetch("required", []),
          inhibitors: data.fetch("inhibitors", []),
          options: data.fetch("options", {}),
          authoritative_capable: false
        )
      rescue KeyError => e
        raise InvalidPolicy, "conditions missing #{e.key}"
      end

      def initialize(registry: Registry.default)
        @registry = registry
        @rules = {}
      end

      def add(transition:, required: [], inhibitors: [], options: {}, authoritative_capable: false)
        rule = build_rule(
          transition: transition, required: required, inhibitors: inhibitors,
          options: options, authoritative_capable: authoritative_capable
        )
        raise InvalidPolicy, "duplicate gate transition #{rule.transition}" if @rules.key?(rule.transition)

        @rules[rule.transition] = rule
      end

      def rule_for(transition)
        @rules.fetch(transition.to_s) do
          raise InvalidPolicy, "unknown gate transition #{transition.inspect}"
        end
      end

      def each_rule(&block) = @rules.values.each(&block)

      def build_rule(transition:, required:, inhibitors:, options:, authoritative_capable:)
        transition = transition.to_s
        raise InvalidPolicy, "gate transition must be non-empty" if transition.empty?
        required = condition_list(required, role: :requirement)
        inhibitors = condition_list(inhibitors, role: :inhibitor)
        overlap = required & inhibitors
        raise InvalidPolicy, "conditions cannot be both required and inhibitors: #{overlap.join(', ')}" unless overlap.empty?
        options = Hive::StringifyKeys.call(options)
        raise InvalidPolicy, "condition options must be an object" unless options.is_a?(Hash)
        unknown_options = options.keys - OPTION_KEYS
        raise InvalidPolicy, "unknown condition options: #{unknown_options.join(', ')}" unless unknown_options.empty?
        options.each do |key, value|
          raise InvalidPolicy, "condition option #{key} must be boolean" unless value == true || value == false
        end

        GateRule.new(
          version: VERSION, transition: transition, required: required.freeze,
          inhibitors: inhibitors.freeze, options: options.freeze,
          authoritative_capable: authoritative_capable == true
        )
      end

      def freeze
        @rules.freeze
        super
      end

      private

      def condition_list(values, role:)
        list = Array(values).map(&:to_s)
        duplicates = list.select { |name| list.count(name) > 1 }.uniq
        raise InvalidPolicy, "duplicate #{role} conditions: #{duplicates.join(', ')}" unless duplicates.empty?
        list.each do |name|
          definition = @registry.fetch(name)
          unless definition.gate_role == role
            raise InvalidPolicy, "condition #{name} is #{definition.gate_role}, not #{role}"
          end
        end
        list
      rescue RegistryError => e
        raise InvalidPolicy, e.message
      end
    end
  end
end
