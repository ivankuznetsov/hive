require "hive/agent_profiles"
require "hive/agent_skills/manifest"

module Hive
  module AgentSkills
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

    # Hive adapter: resolves configured workflow surfaces into the canonical
    # skill capabilities that the policy-light Skillpack facade can project.
    class TargetResolver
      STAGES = %w[brainstorm plan].freeze
      BROWSER_TEST_CAPABILITY = "ce-test-browser".freeze

      def initialize(config:, project_root:, manifest: Manifest.load)
        @config = config
        @project_root = project_root
        @manifest = manifest
      end

      def resolve(agents: nil, skills: nil)
        targets = @manifest.capability("hive").agents.keys.map { |agent| operating_target(agent) }
        STAGES.each { |stage| targets << stage_target(stage) }
        Array(@config.dig("review", "reviewers")).each_with_index do |spec, index|
          name = spec["name"].to_s
          targets << reviewer_target(spec, name.empty? ? "review.reviewers[#{index}]" : "6-review/#{name}")
        end
        adhoc = @config.dig("review", "adhoc", "reviewers")
        Array(adhoc).each_with_index do |spec, index|
          name = spec["name"].to_s
          targets << reviewer_target(spec, name.empty? ? "review.adhoc.reviewers[#{index}]" : "review.adhoc/#{name}")
        end unless adhoc.nil?
        targets << browser_target if @config.dig("review", "browser_test", "enabled")
        if patrol_enabled?
          Array(@config.dig("patrol", "review", "reviewers")).each_with_index do |spec, index|
            name = spec["name"].to_s
            targets << reviewer_target(spec, name.empty? ? "patrol.review.reviewers[#{index}]" : "patrol.review/#{name}")
          end
        end

        selected = filter(deduplicate(targets.compact), agents: agents, skills: skills)
        deduplicate(with_prerequisites(selected)).freeze
      end

      private

      def operating_target(agent)
        capability = @manifest.capability("hive")
        contract = capability.agent(agent)
        Target.new(
          surfaces: [ "hive.operations" ].freeze,
          kind: "operating",
          agent: agent,
          configured_skill: capability.id,
          invocation: contract.invocation,
          capability_id: capability.id,
          package_id: capability.package_id,
          managed: true
        )
      end

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
        skill = @manifest.capability(BROWSER_TEST_CAPABILITY).id
        target_for(
          surface: "review.browser_test",
          kind: "browser_test",
          agent: @config.dig("review", "browser_test", "agent").to_s,
          configured_skill: skill,
          skill: skill
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

      def with_prerequisites(targets)
        expanded = targets.dup
        present = expanded.filter(&:managed).to_h { |target| [ [ target.agent, target.package_id ], true ] }
        cursor = 0
        while (target = expanded[cursor])
          cursor += 1
          next unless target.managed

          @manifest.package(target.package_id).prerequisites.each do |package_id|
            key = [ target.agent, package_id ]
            next if present[key]

            capability = @manifest.capability_for_package(agent: target.agent, package_id: package_id)
            unless capability
              raise Hive::ConfigError,
                    "package #{target.package_id} requires #{package_id}, which has no #{target.agent} capability"
            end
            contract = capability.agent(target.agent)
            expanded << Target.new(
              surfaces: [ "prerequisite:#{target.package_id}" ].freeze,
              kind: "prerequisite",
              agent: target.agent,
              configured_skill: capability.id,
              invocation: contract.invocation,
              capability_id: capability.id,
              package_id: capability.package_id,
              managed: true
            )
            present[key] = true
          end
        end
        expanded
      end

      def skill_filter_matches?(target, filter)
        candidates = [ target.capability_id, target.configured_skill, target.invocation ].compact
        candidates.include?(filter) ||
          candidates.map { |value| value.delete_prefix("/") }.include?(filter.delete_prefix("/"))
      end
    end
  end
end
