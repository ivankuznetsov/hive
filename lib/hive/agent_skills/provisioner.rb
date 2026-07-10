require "digest"
require "json"

require "hive/agent_skills/adapters/registry"

module Hive
  module AgentSkills
    ProvisioningPlan = Data.define(:inspections, :operations, :conflicts, :filters, :fingerprint) do
      def to_h
        {
          "health" => inspections.map(&:to_h),
          "operations" => operations.map(&:to_h),
          "conflicts" => conflicts,
          "filters" => filters,
          "fingerprint" => fingerprint
        }
      end
    end

    ProvisioningResult = Data.define(
      :preview, :consent, :operation_results, :final_health, :exit_code, :classification
    ) do
      def to_h
        {
          "preview" => preview.to_h,
          "consent" => consent,
          "operation_results" => operation_results.map(&:to_h),
          "final_health" => final_health.map(&:to_h),
          "exit_code" => exit_code,
          "classification" => classification
        }
      end
    end

    class Provisioner
      ACTIONABLE_HEALTH = %w[missing stale incompatible conflicting].freeze

      def initialize(config:, project_root:, manifest: Manifest.load,
                     inspector: nil, adapters: nil, runner: CommandRunner.new,
                     environment: ENV)
        @config = config
        @project_root = project_root
        @manifest = manifest
        @inspector = inspector || Inspector.new(
          config: config,
          project_root: project_root,
          manifest: manifest,
          runner: runner,
          environment: environment
        )
        @adapters = adapters || Adapters::Registry.new(
          config: config,
          project_root: project_root,
          manifest: manifest,
          runner: runner,
          environment: environment
        )
      end

      def build_plan(agents: nil, skills: nil)
        inspections = @inspector.inspect(agents: agents, skills: skills)
        if !Array(skills).empty? && inspections.any? { |row| !row.managed }
          names = inspections.reject(&:managed).map { |row| row.target.configured_skill }.uniq
          raise Hive::ConfigError, "skill filter selects unmanaged custom skill(s): #{names.join(', ')}"
        end

        operations = []
        conflicts = []
        actionable = inspections.select { |row| row.managed && %w[missing stale].include?(row.health) }
        actionable.group_by(&:agent).each do |agent, rows|
          adapter_plan = @adapters.fetch(agent).plan(rows)
          operations.concat(adapter_plan.operations)
          conflicts.concat(adapter_plan.conflicts)
        end
        filters = {
          "agents" => Array(agents).map(&:to_s).freeze,
          "skills" => Array(skills).map(&:to_s).freeze
        }.freeze
        fingerprint = fingerprint_for(inspections, operations, conflicts, filters)
        ProvisioningPlan.new(
          inspections: inspections.freeze,
          operations: operations.freeze,
          conflicts: conflicts.freeze,
          filters: filters,
          fingerprint: fingerprint.freeze
        ).freeze
      end

      def revalidate(plan)
        revised = build_plan(
          agents: plan.filters.fetch("agents"),
          skills: plan.filters.fetch("skills")
        )
        [ revised, revised.fingerprint != plan.fingerprint ]
      end

      def execute(plan, consent_provenance:)
        outcomes = []
        by_id = {}
        plan.operations.each do |operation|
          failed_dependencies = operation.depends_on.reject do |dependency|
            by_id[dependency]&.status == "succeeded"
          end
          outcome = if failed_dependencies.empty?
            @adapters.fetch(operation.agent).execute(operation)
          else
            Adapters::Outcome.new(
              operation_id: operation.id,
              agent: operation.agent,
              package_id: operation.package_id,
              status: "skipped",
              message: "dependency failed or was skipped: #{failed_dependencies.join(', ')}",
              exit_status: nil,
              changed_files: [].freeze
            )
          end
          outcomes << outcome
          by_id[operation.id] = outcome
        end

        final_health = @inspector.inspect(
          agents: plan.filters.fetch("agents"),
          skills: plan.filters.fetch("skills")
        )
        failed = outcomes.any? { |outcome| outcome.status == "failed" }
        residual = actionable_rows(final_health).any? || !plan.conflicts.empty?
        exit_code = failed || residual ? 1 : 0
        ProvisioningResult.new(
          preview: plan,
          consent: { "granted" => true, "provenance" => consent_provenance }.freeze,
          operation_results: outcomes.freeze,
          final_health: final_health.freeze,
          exit_code: exit_code,
          classification: exit_code.zero? ? "success" : "residual_failure"
        ).freeze
      end

      def noop_result(plan)
        residual = actionable_rows(plan.inspections).any? || !plan.conflicts.empty?
        ProvisioningResult.new(
          preview: plan,
          consent: { "granted" => false, "provenance" => "not_required" }.freeze,
          operation_results: [].freeze,
          final_health: plan.inspections,
          exit_code: residual ? 1 : 0,
          classification: residual ? "residual_failure" : "no_op"
        ).freeze
      end

      def refusal_result(plan, provenance:)
        ProvisioningResult.new(
          preview: plan,
          consent: { "granted" => false, "provenance" => provenance }.freeze,
          operation_results: [].freeze,
          final_health: plan.inspections,
          exit_code: Hive::ExitCodes::USAGE,
          classification: "refused"
        ).freeze
      end

      private

      def actionable_rows(rows)
        rows.select { |row| row.managed && ACTIONABLE_HEALTH.include?(row.health) }
      end

      def fingerprint_for(inspections, operations, conflicts, filters)
        data = {
          "health" => inspections.map do |row|
            {
              "agent" => row.agent,
              "capability" => row.capability_id,
              "health" => row.health,
              "package" => row.native["package"],
              "marketplace" => row.native["marketplace"],
              "path" => row.resolution["path"]
            }
          end,
          "operations" => operations.map(&:to_h),
          "conflicts" => conflicts,
          "filters" => filters
        }
        Digest::SHA256.hexdigest(JSON.generate(canonical(data)))
      end

      def canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [ key, canonical(value.fetch(key)) ] }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end
    end
  end
end
