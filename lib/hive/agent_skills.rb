require "hive/version"
require "hive/agent_skills/errors"
require "hive/agent_skills/canonical_skill"
require "hive/agent_skills/directory_publisher"

module Hive
  # Policy-light compilation and atomic publication for canonical agent
  # skills. Hive configuration resolves which projections are needed above
  # this facade; this boundary owns deterministic bytes and stale-safe writes.
  module AgentSkills
    Projection = CanonicalSkill::Projection
    ProjectionReport = DirectoryPublisher::Report

    Plan = Data.define(
      :action, :projection, :root, :trusted_root, :inspection
    ) do
      ACTIONS = %w[noop publish refuse].freeze

      def initialize(action:, projection:, root:, trusted_root:, inspection:)
        action = action.to_s
        raise ArgumentError, "unknown agent skill plan action #{action.inspect}" unless ACTIONS.include?(action)
        unless projection.is_a?(Projection)
          raise ArgumentError, "projection must be a Hive::AgentSkills::Projection"
        end
        unless inspection.is_a?(ProjectionReport)
          raise ArgumentError, "inspection must be a Hive::AgentSkills::ProjectionReport"
        end

        root = File.expand_path(root)
        trusted_root = File.expand_path(trusted_root)
        expected_destination = File.join(root, projection.destination_relative)
        unless inspection.destination == expected_destination
          raise ArgumentError, "inspection destination does not match projection root"
        end

        super(
          action: action.freeze,
          projection: projection,
          root: root.freeze,
          trusted_root: trusted_root.freeze,
          inspection: inspection
        )
      end

      def to_h
        {
          "action" => action,
          "projection" => projection.to_h,
          "root" => root,
          "trusted_root" => trusted_root,
          "inspection" => {
            "state" => inspection.state,
            "destination" => inspection.destination,
            "issues" => inspection.issues
          }
        }
      end
    end

    module_function

    def render(platform, source_root: CanonicalSkill.default_root, hive_version: Hive::VERSION)
      CanonicalSkill.new(root: source_root, hive_version: hive_version).render(platform)
    end

    def inspect(root:, trusted_root:, projection:, allowed_extra_files: [])
      publisher(
        root: root,
        trusted_root: trusted_root,
        projection: projection
      ).report(allowed_extra_files: allowed_extra_files)
    end

    def plan(root:, trusted_root:, projection:)
      root = File.expand_path(root)
      trusted_root = File.expand_path(trusted_root)
      inspection = inspect(root: root, trusted_root: trusted_root, projection: projection)
      action =
        if inspection.state == "healthy" && inspection.issues.empty?
          "noop"
        elsif %w[absent stale].include?(inspection.state) &&
              Array(inspection.snapshot["orphans"]).empty?
          "publish"
        else
          "refuse"
        end

      Plan.new(
        action: action,
        projection: projection,
        root: root,
        trusted_root: trusted_root,
        inspection: inspection
      ).freeze
    end

    def apply(plan)
      raise ArgumentError, "expected Hive::AgentSkills::Plan" unless plan.is_a?(Plan)

      target = publisher(
        root: plan.root,
        trusted_root: plan.trusted_root,
        projection: plan.projection
      )
      case plan.action
      when "publish"
        target.publish(expected_snapshot: plan.inspection.snapshot)
      when "noop"
        current = target.report
        unless current.snapshot == plan.inspection.snapshot &&
               current.state == "healthy" && current.issues.empty?
          raise StalePlan, "agent skill destination changed since preview"
        end
        current
      when "refuse"
        details = plan.inspection.issues.map(&:last).join("; ")
        raise ForeignContent, details.empty? ? "agent skill projection is not publishable" : details
      end
    end

    # Hive-only composition factories keep configuration and workflow target
    # resolution above the policy-light projection API. They are lazy so the
    # supported entry point still clean-loads without Hive orchestration.
    def hive_inspector(**arguments)
      require "hive/agent_skills/inspector"
      Inspector.new(**arguments)
    end

    def hive_provisioner(**arguments)
      require "hive/agent_skills/provisioner"
      Provisioner.new(**arguments)
    end

    def same_source?(actual, expected)
      normalize_source(actual) == normalize_source(expected)
    end

    def normalize_source(value)
      value.to_s.strip.sub(%r{\Ahttps://github\.com/}i, "").sub(/\.git\z/i, "").downcase
    end

    def publisher(root:, trusted_root:, projection:)
      DirectoryPublisher.new(
        root: root,
        trusted_root: trusted_root,
        projection: projection
      )
    end
    private_class_method :publisher
  end
end
