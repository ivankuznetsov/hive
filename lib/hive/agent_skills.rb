require "open3"
require "timeout"

require "hive/agent_profiles"
require "hive/agent_skills/manifest"

module Hive
  # Manifest-driven inspection and provisioning for Hive-owned built-in
  # workflow capabilities. Custom user skills remain visible but unmanaged.
  module AgentSkills
    CommandResult = Data.define(:stdout, :stderr, :exit_status, :error, :timed_out) do
      def success?
        !timed_out && error.nil? && exit_status == 0
      end
    end

    class CommandRunner
      def call(argv, env: {}, timeout: 10)
        stdout, stderr, status = Timeout.timeout(timeout) do
          Open3.capture3(env, *argv)
        end
        CommandResult.new(
          stdout: stdout,
          stderr: stderr,
          exit_status: status.exitstatus,
          error: nil,
          timed_out: false
        )
      rescue Timeout::Error => e
        CommandResult.new(stdout: "", stderr: "", exit_status: nil, error: e.message, timed_out: true)
      rescue SystemCallError => e
        CommandResult.new(stdout: "", stderr: "", exit_status: nil, error: "#{e.class}: #{e.message}", timed_out: false)
      end
    end

    Target = Data.define(
      :surfaces, :kind, :agent, :configured_skill, :invocation,
      :capability_id, :package_id, :managed
    ) do
      def to_h
        {
          "surfaces" => surfaces,
          "kind" => kind,
          "agent" => agent,
          "configured_skill" => configured_skill,
          "invocation" => invocation,
          "capability" => capability_id,
          "package" => package_id,
          "managed" => managed
        }
      end
    end

    # Resolves the effective built-in skill surface into one row per
    # agent/capability. Duplicate uses retain every source surface while
    # package work can later deduplicate independently.
    class TargetResolver
      STAGES = %w[brainstorm plan].freeze

      def initialize(config:, project_root:, manifest: Manifest.load)
        @config = config
        @project_root = project_root
        @manifest = manifest
      end

      def resolve(agents: nil, skills: nil)
        targets = []
        STAGES.each { |stage| targets << stage_target(stage) }
        Array(@config.dig("review", "reviewers")).each_with_index do |spec, index|
          targets << reviewer_target(spec, "review.reviewers[#{index}]")
        end
        adhoc = @config.dig("review", "adhoc", "reviewers")
        Array(adhoc).each_with_index do |spec, index|
          targets << reviewer_target(spec, "review.adhoc.reviewers[#{index}]")
        end unless adhoc.nil?
        targets << browser_target if @config.dig("review", "browser_test", "enabled")
        if patrol_enabled?
          Array(@config.dig("patrol", "review", "reviewers")).each_with_index do |spec, index|
            targets << reviewer_target(spec, "patrol.review.reviewers[#{index}]")
          end
        end

        filter(deduplicate(targets.compact), agents: agents, skills: skills)
      end

      private

      def stage_target(stage)
        agent = (@config.dig(stage, "agent") || "claude").to_s
        configured = (@config.dig(stage, "skill") || Hive::Config.stage_skill(@config, stage)).to_s
        target_for(
          surface: stage,
          kind: "stage",
          agent: agent,
          configured_skill: configured,
          skill: Hive::Config.stage_skill(@config, stage)
        )
      end

      def reviewer_target(spec, surface)
        kind = (spec["kind"] || "agent").to_s
        agent = spec["agent"].to_s
        skill = spec["skill"].to_s
        unless kind == "agent"
          return Target.new(
            surfaces: [ surface ].freeze,
            kind: kind,
            agent: agent,
            configured_skill: skill,
            invocation: skill,
            capability_id: nil,
            package_id: nil,
            managed: false
          )
        end

        target_for(
          surface: surface,
          kind: "reviewer",
          agent: agent,
          configured_skill: skill,
          skill: skill
        )
      end

      def browser_target
        require "hive/stages/review/browser_test"
        target_for(
          surface: "review.browser_test",
          kind: "browser_test",
          agent: @config.dig("review", "browser_test", "agent").to_s,
          configured_skill: Hive::Stages::Review::BrowserTest::SKILL,
          skill: Hive::Stages::Review::BrowserTest::SKILL
        )
      end

      def target_for(surface:, kind:, agent:, configured_skill:, skill:)
        profile = Hive::AgentProfiles.lookup(agent, cfg: @config)
        invocation = profile.format_skill_invocation(skill)
        capability = @manifest.capability_for(agent: agent, invocation: invocation)
        Target.new(
          surfaces: [ surface ].freeze,
          kind: kind,
          agent: agent,
          configured_skill: configured_skill.to_s,
          invocation: invocation,
          capability_id: capability&.id,
          package_id: capability&.package_id,
          managed: !capability.nil?
        )
      end

      def patrol_enabled?
        patrol = @config["patrol"]
        return false unless patrol.is_a?(Hash)
        return patrol["enabled"] unless patrol["enabled"].nil?

        mode = patrol["mode"].to_s
        !mode.empty? && mode != "off"
      end

      def deduplicate(targets)
        targets.each_with_object({}) do |target, out|
          key = [ target.agent, target.capability_id || target.invocation, target.kind == "browser_test" ]
          if (existing = out[key])
            out[key] = Target.new(
              surfaces: (existing.surfaces + target.surfaces).uniq.freeze,
              kind: existing.kind,
              agent: existing.agent,
              configured_skill: existing.configured_skill,
              invocation: existing.invocation,
              capability_id: existing.capability_id,
              package_id: existing.package_id,
              managed: existing.managed
            )
          else
            out[key] = target
          end
        end.values
      end

      def filter(targets, agents:, skills:)
        agent_filters = Array(agents).map(&:to_s).reject(&:empty?)
        skill_filters = Array(skills).map(&:to_s).reject(&:empty?)

        unless agent_filters.empty?
          present = targets.map(&:agent).uniq
          unknown = agent_filters - present
          raise Hive::ConfigError, "agent filter(s) not configured: #{unknown.join(', ')}" unless unknown.empty?
          targets = targets.select { |target| agent_filters.include?(target.agent) }
        end

        unless skill_filters.empty?
          unknown = skill_filters.reject do |filter|
            targets.any? { |target| skill_filter_matches?(target, filter) }
          end
          raise Hive::ConfigError, "skill filter(s) not configured: #{unknown.join(', ')}" unless unknown.empty?
          targets = targets.select { |target| skill_filters.any? { |filter| skill_filter_matches?(target, filter) } }
        end
        targets.freeze
      end

      def skill_filter_matches?(target, filter)
        candidates = [ target.capability_id, target.configured_skill, target.invocation ].compact
        candidates.include?(filter) || candidates.map { |value| value.delete_prefix("/") }.include?(filter.delete_prefix("/"))
      end
    end
  end
end
