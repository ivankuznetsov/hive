module Hive
  module Conditions
    class RegistryError < Hive::Error; end

    Definition = Data.define(
      :name, :family, :supersession_family, :scope, :allowed_evidence,
      :gate_role, :authoritative_stages, :default_transitions
    ) do
      def authoritative_for?(stage)
        authoritative_stages.include?(stage.to_s)
      end

      def to_h
        {
          "name" => name,
          "family" => family,
          "supersession_family" => supersession_family,
          "scope" => scope.to_s,
          "allowed_evidence" => allowed_evidence.map(&:to_s),
          "gate_role" => gate_role.to_s,
          "authoritative_stages" => authoritative_stages,
          "default_transitions" => default_transitions
        }
      end
    end

    class Registry
      include Enumerable

      def self.default
        @default ||= begin
          registry = new
          registry.register(
            "AgentHealthy", family: "agent_health", supersession_family: "agent_health",
            scope: :attempt, allowed_evidence: %i[attempt_lease journal_event],
            gate_role: :requirement, authoritative_stages: [ "4-execute" ], # coding-scoped: increment 1 gate
            default_transitions: [ "execute_active" ]
          )
          registry.register(
            "ChangesPresent", family: "changes_present", supersession_family: "execute_outcome",
            scope: :commit, allowed_evidence: %i[commit journal_event file],
            gate_role: :requirement, authoritative_stages: [ "4-execute" ], # coding-scoped: increment 1 gate
            default_transitions: [ "execute_to_open_pr" ]
          )
          registry.register(
            "AwaitingHuman", family: "awaiting_human", supersession_family: "execute_outcome",
            scope: :attempt, allowed_evidence: %i[journal_event attempt_lease],
            gate_role: :inhibitor, authoritative_stages: [ "4-execute" ], # coding-scoped: increment 1 gate
            default_transitions: [ "execute_to_open_pr" ]
          )
          registry.register(
            "BranchPushed", family: "branch_pushed", supersession_family: "branch_pushed",
            scope: :commit, allowed_evidence: %i[commit journal_event],
            gate_role: :requirement, default_transitions: [ "open_pr_to_review" ]
          )
          registry.register(
            "ArtifactCurrent", family: "artifact_current", supersession_family: "artifact_current",
            scope: :commit, allowed_evidence: %i[file commit journal_event],
            gate_role: :requirement, default_transitions: [ "artifacts_to_finalize" ]
          )
          registry.register(
            "BabysitterActive", family: "babysitter_active", supersession_family: "babysitter_active",
            scope: :attempt, allowed_evidence: %i[attempt_lease journal_event],
            gate_role: :requirement, default_transitions: [ "review_active" ]
          )
          registry.register(
            "Merged", family: "merged", supersession_family: "merged",
            scope: :pull_request, allowed_evidence: %i[pull_request journal_event],
            gate_role: :informational, default_transitions: [ "finalize_to_archive" ]
          )
          registry.register(
            "ArchiveReady", family: "archive_ready", supersession_family: "archive_ready",
            scope: :task, allowed_evidence: %i[journal_event],
            gate_role: :requirement, default_transitions: [ "finalize_to_archive" ]
          )
          registry.freeze
        end
      end

      def initialize
        @by_name = {}
        @families = {}
      end

      def register(name, family:, scope:, allowed_evidence:, gate_role:,
                   supersession_family: family, authoritative_stages: [], default_transitions: [])
        name = name.to_s
        family = family.to_s
        raise RegistryError, "condition name must be non-empty" if name.empty?
        raise RegistryError, "duplicate condition #{name}" if @by_name.key?(name)
        raise RegistryError, "duplicate condition family #{family}" if @families.key?(family)

        definition = Definition.new(
          name: name,
          family: family,
          supersession_family: supersession_family.to_s,
          scope: scope.to_sym,
          allowed_evidence: Array(allowed_evidence).map(&:to_sym).freeze,
          gate_role: gate_role.to_sym,
          authoritative_stages: Array(authoritative_stages).map(&:to_s).freeze,
          default_transitions: Array(default_transitions).map(&:to_s).freeze
        )
        unless %i[attempt commit pull_request task].include?(definition.scope)
          raise RegistryError, "condition #{name} has unknown scope #{scope.inspect}"
        end
        unless %i[requirement inhibitor informational].include?(definition.gate_role)
          raise RegistryError, "condition #{name} has unknown gate role #{gate_role.inspect}"
        end

        @by_name[name] = definition
        @families[family] = definition
        definition
      end

      def fetch(name)
        @by_name.fetch(name.to_s) do
          raise RegistryError, "unknown condition #{name.inspect}"
        end
      end

      def key?(name) = @by_name.key?(name.to_s)
      def each(&block) = @by_name.values.each(&block)
      def names = @by_name.keys.freeze
      def size = @by_name.size

      def freeze
        @by_name.freeze
        @families.freeze
        super
      end
    end
  end
end
