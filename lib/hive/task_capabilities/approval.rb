require "hive/task_capabilities/policy"
require "hive/task_capabilities/plan"
require "hive/scripts/workflow_policy_hook"

module Hive
  module TaskCapabilities
    # An operator-written reference authorizes only a subset of its exact route.
    class Approval
      attr_reader :reference, :envelope

      def initialize(reference:, envelope:)
        Definition.identifier(reference, label: "capability approval reference")
        @reference = reference
        @envelope = Plan.redact(Hive::WorkflowPackage::CanonicalJSON.normalize(envelope))
        Definition.deep_freeze(@envelope)
      end

      def covers?(requested)
        return false unless requested.is_a?(Hash) && requested["capability"] == envelope["capability"] && requested["actor"] == envelope["actor"]
        return false unless %w[budget_usd timeout_sec].all? { |key| requested[key].is_a?(Numeric) && requested[key].positive? && requested[key] <= envelope.fetch(key) }
        return false unless requested["targets"].is_a?(Array) && (requested["targets"] - envelope.fetch("targets")).empty?
        self.class.permissions_within?(requested["permissions"], envelope.fetch("permissions"))
      end

      def self.permissions_within?(requested, approved)
        return false unless requested.is_a?(Hash)
        Hive::WorkflowPackage::RuntimePolicy.validate_spec!(requested)
        return false unless (approved.fetch("deny", []) - requested.fetch("deny", [])).empty?
        requested.all? do |key, value|
          case key
          when "deny" then true
          when "commands"
            value.all? { |command| Hive::Scripts::WorkflowPolicyHook.command_declared?({ "commands" => approved.fetch("commands", []) }, Shellwords.shellsplit(command)) }
          else (value - approved.fetch(key, [])).empty?
          end
        end
      rescue Hive::ConfigError
        false
      end

      def blob(task_identity:)
        Plan.redact({ "schema_version" => 1, "task" => task_identity,
                      "reference" => reference, "envelope" => envelope, "source" => "operator-written" })
      end
    end
  end
end
