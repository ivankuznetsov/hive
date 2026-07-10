require "yaml"
require "pathname"
require "rubygems/requirement"

require "hive/config"

module Hive
  module AgentSkills
    # Strict loader for config/agent-skills.yml. The manifest is intentionally
    # data-only: adapters map its closed action names to argv arrays.
    class Manifest
      SUPPORTED_SCHEMA_VERSION = 1
      AGENTS = %w[claude codex pi].freeze
      ACTIONS = %w[
        marketplace_add plugin_install plugin_update package_install package_update
      ].freeze
      CONFIG_HOMES = %w[CLAUDE_CONFIG_DIR CODEX_HOME PI_CODING_AGENT_DIR].freeze
      SAFE_ID = /\A[a-z0-9][a-z0-9._:-]*\z/
      SAFE_SOURCE = %r{\A(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?)\z}
      SAFE_PACKAGE = %r{\A(?:[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+|https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?)\z}
      SAFE_RELATIVE_PATH = %r{\A(?!/)(?!.*(?:\A|/)\.\.(?:/|\z))[A-Za-z0-9._/-]+\z}
      CLAUDE_ALIAS_ROOT = ".claude/commands/"

      class ValidationError < Hive::ConfigError; end
      class CoverageError < ValidationError; end

      AliasSpec = Data.define(:path, :target, :owner)
      NativePackage = Data.define(
        :agent, :provider, :package, :marketplace, :source, :scope,
        :config_home, :actions
      )
      Package = Data.define(:id, :version, :requirement, :agents) do
        def native_for(agent)
          agents.fetch(agent.to_s)
        end
      end
      AgentContract = Data.define(:agent, :invocation, :probe, :alias_spec)
      Capability = Data.define(:id, :package_id, :agents) do
        def agent(name)
          agents.fetch(name.to_s)
        end
      end

      attr_reader :schema_version, :packages, :capabilities, :source

      def self.default_path
        File.expand_path("../../../config/agent-skills.yml", __dir__)
      end

      def self.load(path = default_path)
        parse(YAML.safe_load(File.read(path), permitted_classes: [], aliases: false), source: path)
      rescue Psych::Exception, Errno::ENOENT, Errno::EACCES => e
        raise ValidationError, "agent skills manifest #{path}: #{e.message}"
      end

      def self.parse(document, source: "agent skills manifest")
        new(document, source: source)
      end

      def self.alias_content(alias_spec)
        "<!-- hive-managed: agent-skill-alias/v1 -->\n" \
          "Invoke `#{alias_spec.target}` with all arguments supplied to this command.\n"
      end

      # Declarations come from the runtime defaults themselves. Reviewer
      # names are derived from Init::Prompts::REVIEWER_CAPABILITIES and the
      # browser skill is supplied by BrowserTest::SKILL, avoiding a second
      # copied list in the manifest subsystem.
      def self.builtin_declarations(config:, reviewer_capabilities:, browser_test_skill:)
        declarations = %w[brainstorm plan].map do |stage|
          agent = config.dig(stage, "agent").to_s
          invocation = Hive::Config.stage_skill(config, stage).to_s
          {
            surface: stage,
            agent: agent,
            capability: capability_id_for_invocation(invocation)
          }
        end

        reviewer_capabilities.each do |name, spec|
          next unless spec.fetch("kind", "agent") == "agent"

          declarations << {
            surface: "review.reviewers/#{name}",
            agent: spec.fetch("agent"),
            capability: spec.fetch("capability")
          }
        end

        if config.dig("review", "browser_test", "enabled")
          declarations << {
            surface: "review.browser_test",
            agent: config.dig("review", "browser_test", "agent").to_s,
            capability: capability_id_for_invocation(browser_test_skill)
          }
        end

        declarations.freeze
      end

      def self.capability_id_for_invocation(invocation)
        raw = invocation.to_s.delete_prefix("/")
        return "wiki-plan" if raw == "plan" || raw.end_with?(":wiki-plan") || raw == "skill:wiki-plan"

        raw = raw.delete_prefix("skill:")
        raw = raw.split(":", 2).last if raw.start_with?("compound-engineering:")
        raw
      end

      def initialize(document, source:)
        @source = source
        root = expect_hash(document, source)
        assert_keys!(root, %w[schema_version packages capabilities], source)
        @schema_version = root.fetch("schema_version")
        unless @schema_version == SUPPORTED_SCHEMA_VERSION
          invalid!("#{source}.schema_version", "unsupported #{@schema_version.inspect}; expected #{SUPPORTED_SCHEMA_VERSION}")
        end

        @packages = parse_packages(root.fetch("packages")).freeze
        @package_index = index_unique(@packages, "package").freeze
        @capabilities = parse_capabilities(root.fetch("capabilities")).freeze
        @capability_index = index_unique(@capabilities, "capability").freeze
        validate_references!
        freeze
      rescue KeyError => e
        raise ValidationError, "#{source}: missing required key #{e.key.inspect}"
      end

      def package(id)
        @package_index.fetch(id.to_s)
      end

      def capability(id)
        @capability_index.fetch(id.to_s)
      end

      def capability_for(agent:, invocation:)
        normalized = invocation.to_s
        @capabilities.find do |capability|
          contract = capability.agents[agent.to_s]
          contract && contract.invocation == normalized
        end
      end

      def validate_default_coverage!(declarations)
        missing = declarations.filter_map do |row|
          capability = @capability_index[row.fetch(:capability).to_s]
          next "#{row.fetch(:surface)} -> #{row.fetch(:capability)} (undeclared)" unless capability
          next if capability.agents.key?(row.fetch(:agent).to_s)

          "#{row.fetch(:surface)} -> #{row.fetch(:capability)} (unsupported for #{row.fetch(:agent)})"
        end
        return true if missing.empty?

        raise CoverageError, "built-in agent skill coverage missing: #{missing.join('; ')}"
      end

      private

      def parse_packages(value)
        expect_array(value, "#{@source}.packages").each_with_index.map do |entry, index|
          path = "#{@source}.packages[#{index}]"
          row = expect_hash(entry, path)
          assert_keys!(row, %w[id version agents], path)
          id = safe_id!(row.fetch("id"), "#{path}.id")
          version = string!(row.fetch("version"), "#{path}.version")
          requirement = Gem::Requirement.new(version)
          agents = parse_native_agents(row.fetch("agents"), "#{path}.agents")
          Package.new(id: id, version: version, requirement: requirement, agents: agents.freeze)
        rescue Gem::Requirement::BadRequirementError => e
          invalid!("#{path}.version", e.message)
        end
      end

      def parse_native_agents(value, path)
        rows = expect_hash(value, path)
        invalid!(path, "must declare at least one agent") if rows.empty?
        rows.each_with_object({}) do |(agent, entry), out|
          validate_agent!(agent, path)
          row_path = "#{path}.#{agent}"
          row = expect_hash(entry, row_path)
          assert_keys!(row, %w[provider package marketplace source scope config_home actions], row_path,
                       required: %w[provider package source scope config_home actions])
          provider = string!(row.fetch("provider"), "#{row_path}.provider")
          invalid!("#{row_path}.provider", "must equal agent #{agent.inspect}") unless provider == agent
          package = string!(row.fetch("package"), "#{row_path}.package")
          invalid!("#{row_path}.package", "contains an unsafe package selector") unless SAFE_PACKAGE.match?(package)
          source = string!(row.fetch("source"), "#{row_path}.source")
          invalid!("#{row_path}.source", "contains an unsafe source") unless SAFE_SOURCE.match?(source)
          scope = string!(row.fetch("scope"), "#{row_path}.scope")
          invalid!("#{row_path}.scope", "must be user") unless scope == "user"
          config_home = string!(row.fetch("config_home"), "#{row_path}.config_home")
          invalid!("#{row_path}.config_home", "is not supported") unless CONFIG_HOMES.include?(config_home)
          actions = expect_array(row.fetch("actions"), "#{row_path}.actions").map do |action|
            action = string!(action, "#{row_path}.actions")
            invalid!("#{row_path}.actions", "unknown action #{action.inspect}") unless ACTIONS.include?(action)
            action
          end
          invalid!("#{row_path}.actions", "must not be empty") if actions.empty?
          NativePackage.new(
            agent: agent,
            provider: provider,
            package: package,
            marketplace: optional_string(row["marketplace"], "#{row_path}.marketplace"),
            source: source,
            scope: scope,
            config_home: config_home,
            actions: actions.freeze
          ).then { |native| out[agent] = native }
        end
      end

      def parse_capabilities(value)
        expect_array(value, "#{@source}.capabilities").each_with_index.map do |entry, index|
          path = "#{@source}.capabilities[#{index}]"
          row = expect_hash(entry, path)
          assert_keys!(row, %w[id package agents], path)
          id = safe_id!(row.fetch("id"), "#{path}.id")
          package_id = safe_id!(row.fetch("package"), "#{path}.package")
          agents = parse_capability_agents(row.fetch("agents"), "#{path}.agents")
          Capability.new(id: id, package_id: package_id, agents: agents.freeze)
        end
      end

      def parse_capability_agents(value, path)
        rows = expect_hash(value, path)
        invalid!(path, "must declare at least one agent") if rows.empty?
        rows.each_with_object({}) do |(agent, entry), out|
          validate_agent!(agent, path)
          row_path = "#{path}.#{agent}"
          row = expect_hash(entry, row_path)
          assert_keys!(row, %w[invocation probe alias], row_path, required: %w[invocation probe])
          invocation = string!(row.fetch("invocation"), "#{row_path}.invocation")
          invalid!("#{row_path}.invocation", "must be a slash invocation") unless invocation.match?(%r{\A/[A-Za-z0-9_.:-]+\z})
          probe = safe_relative_path!(row.fetch("probe"), "#{row_path}.probe")
          alias_spec = row.key?("alias") ? parse_alias(row.fetch("alias"), "#{row_path}.alias", agent) : nil
          out[agent] = AgentContract.new(agent: agent, invocation: invocation, probe: probe, alias_spec: alias_spec)
        end
      end

      def parse_alias(value, path, agent)
        invalid!(path, "aliases are supported only for claude") unless agent == "claude"
        row = expect_hash(value, path)
        assert_keys!(row, %w[path target owner], path)
        alias_path = safe_relative_path!(row.fetch("path"), "#{path}.path")
        unless alias_path.start_with?(CLAUDE_ALIAS_ROOT) && alias_path.end_with?(".md")
          invalid!("#{path}.path", "must be a markdown file under #{CLAUDE_ALIAS_ROOT}")
        end
        target = string!(row.fetch("target"), "#{path}.target")
        invalid!("#{path}.target", "must be a slash invocation") unless target.match?(%r{\A/[A-Za-z0-9_.:-]+\z})
        owner = string!(row.fetch("owner"), "#{path}.owner")
        invalid!("#{path}.owner", "must be hive") unless owner == "hive"
        AliasSpec.new(path: alias_path, target: target, owner: owner)
      end

      def validate_references!
        @capabilities.each do |capability|
          package = @package_index[capability.package_id]
          invalid!("capability #{capability.id}", "references unknown package #{capability.package_id.inspect}") unless package
          capability.agents.each_key do |agent|
            next if package.agents.key?(agent)

            invalid!("capability #{capability.id}", "supports #{agent} but package #{package.id} does not")
          end
        end
      end

      def index_unique(rows, label)
        rows.each_with_object({}) do |row, out|
          invalid!(@source, "duplicate #{label} id #{row.id.inspect}") if out.key?(row.id)
          out[row.id] = row
        end
      end

      def assert_keys!(hash, allowed, path, required: allowed)
        unknown = hash.keys - allowed
        invalid!(path, "unknown keys: #{unknown.sort.join(', ')}") unless unknown.empty?
        missing = required - hash.keys
        invalid!(path, "missing keys: #{missing.sort.join(', ')}") unless missing.empty?
      end

      def expect_hash(value, path)
        invalid!(path, "must be a Hash; got #{value.class}") unless value.is_a?(Hash)
        value
      end

      def expect_array(value, path)
        invalid!(path, "must be an Array; got #{value.class}") unless value.is_a?(Array)
        value
      end

      def string!(value, path)
        invalid!(path, "must be a non-empty String") unless value.is_a?(String) && !value.empty?
        value
      end

      def optional_string(value, path)
        value.nil? ? nil : string!(value, path)
      end

      def safe_id!(value, path)
        value = string!(value, path)
        invalid!(path, "contains unsafe characters") unless SAFE_ID.match?(value)
        value
      end

      def safe_relative_path!(value, path)
        value = string!(value, path)
        invalid!(path, "must be a safe relative path") unless SAFE_RELATIVE_PATH.match?(value)
        value
      end

      def validate_agent!(agent, path)
        invalid!(path, "unknown agent #{agent.inspect}") unless AGENTS.include?(agent)
      end

      def invalid!(path, message)
        raise ValidationError, "#{path}: #{message}"
      end
    end
  end
end
