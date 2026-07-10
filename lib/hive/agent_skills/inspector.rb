require "json"
require "rubygems/version"

require "hive/agent_skills"
require "hive/skill_check"

module Hive
  module AgentSkills
    Inspection = Data.define(
      :target, :expected, :native, :resolution, :health, :severity,
      :explanation, :remediation
    ) do
      def agent = target.agent
      def capability_id = target.capability_id
      def package_id = target.package_id
      def managed = target.managed
      def surfaces = target.surfaces

      def to_h
        {
          "agent" => agent,
          "capability" => capability_id,
          "package" => package_id,
          "surfaces" => surfaces,
          "managed" => managed,
          "expected" => expected,
          "native" => native,
          "resolution" => resolution,
          "health" => health,
          "severity" => severity,
          "explanation" => explanation,
          "remediation" => remediation
        }
      end
    end

    # Shared read-only health model used by doctor and setup. Native inventory
    # is evidence, but a row is healthy only when SkillCheck resolves the exact
    # runtime invocation from the expected package (or Hive-owned alias).
    class Inspector
      HEALTH_PRECEDENCE = %w[conflicting incompatible unavailable stale missing healthy].freeze
      INVENTORY_TIMEOUT_SEC = 10

      def initialize(config:, project_root:, manifest: Manifest.load,
                     resolver: nil, runner: CommandRunner.new, environment: ENV)
        @config = config
        @project_root = project_root && File.expand_path(project_root)
        @manifest = manifest
        @resolver = resolver || TargetResolver.new(
          config: config, project_root: @project_root, manifest: manifest
        )
        @runner = runner
        @environment = environment
        @native_cache = {}
      end

      def inspect(agents: nil, skills: nil)
        @resolver.resolve(agents: agents, skills: skills).map { |target| inspect_target(target) }.freeze
      end

      private

      def inspect_target(target)
        return inspect_unmanaged(target) unless target.managed

        capability = @manifest.capability(target.capability_id)
        package = @manifest.package(capability.package_id)
        contract = capability.agent(target.agent)
        native_spec = package.native_for(target.agent)
        expected = {
          "package" => native_spec.package,
          "package_id" => package.id,
          "version" => package.version,
          "source" => native_spec.source,
          "marketplace" => native_spec.marketplace,
          "invocation" => contract.invocation,
          "probe" => contract.probe,
          "alias" => alias_hash(contract.alias_spec)
        }.freeze

        profile = Hive::AgentProfiles.lookup(target.agent, cfg: @config)
        bin = resolved_binary(profile)
        unless bin
          return build_inspection(
            target: target,
            expected: expected,
            native: unavailable_native(profile),
            resolution: empty_resolution,
            issues: [ [ "unavailable", "#{profile.bin_default} is not executable or on PATH" ] ]
          )
        end

        native = @native_cache[[ target.agent, package.id ]] ||= inspect_native(
          profile: profile, bin: bin, package: package, native_spec: native_spec
        )
        resolution = inspect_resolution(target, contract, native)
        issues = native.fetch("issues").map(&:dup)
        issues.concat(resolution.fetch("issues"))
        issues.concat(package_version_issues(package, native.fetch("package")))
        issues.concat(runtime_issues(native.fetch("package"), resolution))
        issues.concat(source_issues(native_spec, native))

        build_inspection(
          target: target,
          expected: expected,
          native: native.reject { |key, _| key == "issues" }.freeze,
          resolution: resolution.reject { |key, _| key == "issues" }.freeze,
          issues: issues
        )
      end

      def inspect_unmanaged(target)
        profile = Hive::AgentProfiles.lookup(target.agent, cfg: @config) unless target.agent.empty?
        bin = profile && resolved_binary(profile)
        if !profile || !bin
          return build_inspection(
            target: target,
            expected: { "managed" => false }.freeze,
            native: unavailable_native(profile),
            resolution: empty_resolution,
            issues: [ [ "unavailable", "agent is unavailable for unmanaged capability" ] ]
          )
        end

        if target.kind == "agent" || target.kind == "reviewer"
          resolved = skill_module(target.agent).resolve(
            target.invocation, project_root: @project_root, environment: @environment
          )
          health = resolved.status == :present ? "healthy" : "missing"
          issue = health == "healthy" ? [] : [ [ "missing", resolved.message ] ]
          return build_inspection(
            target: target,
            expected: { "managed" => false }.freeze,
            native: { "available" => true, "bin" => bin }.freeze,
            resolution: resolution_hash(resolved).freeze,
            issues: issue,
            remediation: "install or configure #{target.configured_skill.inspect} manually; Hive does not manage custom skills"
          )
        end

        build_inspection(
          target: target,
          expected: { "managed" => false }.freeze,
          native: { "available" => true, "bin" => bin }.freeze,
          resolution: empty_resolution,
          issues: [],
          remediation: "native reviewer; no managed skill installation is required"
        )
      end

      def inspect_native(profile:, bin:, package:, native_spec:)
        commands = []
        issues = []
        version_result = run([ bin, profile.version_flag ], commands)
        version = parse_version(version_result.stdout)
        unless version_result.success? && version
          detail = command_failure(version_result, "version output was not parseable")
          issues << [ "incompatible", "#{profile.name} CLI version probe failed: #{detail}" ]
        end
        if version && profile.min_version && Gem::Version.new(version) < Gem::Version.new(profile.min_version)
          issues << [ "incompatible", "#{profile.name} CLI #{version} is below supported #{profile.min_version}" ]
        end

        inventory = case native_spec.provider
        when "claude" then claude_inventory(bin, native_spec, commands, issues)
        when "codex" then codex_inventory(bin, native_spec, commands, issues)
        when "pi" then pi_inventory(bin, native_spec, commands, issues)
        else
          issues << [ "incompatible", "unsupported provider #{native_spec.provider.inspect}" ]
          { "package" => nil, "marketplace" => nil }
        end

        {
          "available" => true,
          "bin" => bin,
          "cli_version" => version,
          "commands" => commands.freeze,
          "package" => inventory.fetch("package"),
          "marketplace" => inventory.fetch("marketplace"),
          "issues" => issues.freeze
        }
      rescue JSON::ParserError, TypeError, KeyError => e
        {
          "available" => true,
          "bin" => bin,
          "cli_version" => nil,
          "commands" => commands.freeze,
          "package" => nil,
          "marketplace" => nil,
          "issues" => [ [ "incompatible", "#{profile.name} native inventory is malformed: #{e.message}" ] ].freeze
        }
      end

      def claude_inventory(bin, native_spec, commands, issues)
        plugins_result = run([ bin, "plugin", "list", "--json" ], commands)
        marketplaces_result = run([ bin, "plugin", "marketplace", "list", "--json" ], commands)
        issues << [ "incompatible", "claude plugin inventory failed: #{command_failure(plugins_result)}" ] unless plugins_result.success?
        issues << [ "incompatible", "claude marketplace inventory failed: #{command_failure(marketplaces_result)}" ] unless marketplaces_result.success?
        plugins = JSON.parse(plugins_result.stdout)
        marketplaces = JSON.parse(marketplaces_result.stdout)
        raise TypeError, "plugin list must be an Array" unless plugins.is_a?(Array)
        raise TypeError, "marketplace list must be an Array" unless marketplaces.is_a?(Array)

        plugin = plugins.find { |entry| entry["id"] == native_spec.package }
        marketplace = marketplaces.find { |entry| entry["name"] == native_spec.marketplace }
        {
          "package" => plugin && {
            "id" => plugin["id"],
            "version" => plugin["version"],
            "enabled" => plugin.fetch("enabled", true),
            "install_path" => plugin["installPath"],
            "source" => nil
          }.freeze,
          "marketplace" => marketplace && {
            "name" => marketplace["name"],
            "source" => marketplace["repo"] || marketplace["source"]
          }.freeze
        }
      end

      def codex_inventory(bin, native_spec, commands, issues)
        plugins_result = run([ bin, "plugin", "list", "--available", "--json" ], commands)
        marketplaces_result = run([ bin, "plugin", "marketplace", "list", "--json" ], commands)
        issues << [ "incompatible", "codex plugin inventory failed: #{command_failure(plugins_result)}" ] unless plugins_result.success?
        issues << [ "incompatible", "codex marketplace inventory failed: #{command_failure(marketplaces_result)}" ] unless marketplaces_result.success?
        plugins_doc = JSON.parse(plugins_result.stdout)
        marketplaces_doc = JSON.parse(marketplaces_result.stdout)
        plugins = plugins_doc.fetch("installed")
        marketplaces = marketplaces_doc.fetch("marketplaces")
        raise TypeError, "installed plugin list must be an Array" unless plugins.is_a?(Array)
        raise TypeError, "marketplace list must be an Array" unless marketplaces.is_a?(Array)

        plugin = plugins.find { |entry| entry["pluginId"] == native_spec.package }
        marketplace = marketplaces.find { |entry| entry["name"] == native_spec.marketplace }
        {
          "package" => plugin && {
            "id" => plugin["pluginId"],
            "version" => plugin["version"],
            "enabled" => plugin.fetch("enabled", true),
            "install_path" => nil,
            "source" => plugin.dig("source", "url") || plugin.dig("marketplaceSource", "source")
          }.freeze,
          "marketplace" => marketplace && {
            "name" => marketplace["name"],
            "source" => marketplace.dig("marketplaceSource", "source")
          }.freeze
        }
      end

      def pi_inventory(bin, native_spec, commands, issues)
        list_result = run([ bin, "list" ], commands)
        issues << [ "incompatible", "pi package inventory failed: #{command_failure(list_result)}" ] unless list_result.success?
        lines = list_result.stdout.lines
        source_index = lines.index { |line| same_source?(line.strip, native_spec.source) }
        install_path = if source_index
          lines[(source_index + 1)..]&.find { |line| !line.strip.empty? }&.strip
        end
        package = source_index && {
          "id" => native_spec.package,
          "version" => package_version_from(install_path),
          "enabled" => true,
          "install_path" => install_path,
          "source" => lines[source_index].strip
        }.freeze
        { "package" => package, "marketplace" => nil }
      end

      def inspect_resolution(target, contract, native)
        issues = []
        alias_path = nil
        invocation = contract.invocation
        if contract.alias_spec
          alias_path = alias_path_for(contract.alias_spec)
          if File.exist?(alias_path)
            actual = File.read(alias_path)
            unless actual == Manifest.alias_content(contract.alias_spec)
              issues << [ "conflicting", "user-owned alias #{alias_path} wins #{target.invocation}; Hive will not replace it" ]
            end
          else
            issues << [ "missing", "Hive-owned alias #{alias_path} is absent" ]
          end
          invocation = contract.alias_spec.target
        end

        resolved = skill_module(target.agent).resolve(
          invocation, project_root: @project_root, environment: @environment
        )
        path = resolved.path
        if path && !expected_resolution_path?(path, target, native)
          issues << [ "conflicting", "unexpected higher-precedence skill #{path} wins #{target.invocation}" ]
        end
        resolution_hash(resolved).merge(
          "invocation" => invocation,
          "alias_path" => alias_path,
          "alias_owned" => contract.alias_spec ? (File.file?(alias_path) && File.read(alias_path) == Manifest.alias_content(contract.alias_spec)) : nil,
          "issues" => issues.freeze
        )
      rescue SystemCallError => e
        {
          "status" => "missing", "path" => nil, "message" => e.message,
          "candidates" => [], "parse_errors" => [], "invocation" => invocation,
          "alias_path" => alias_path, "alias_owned" => false,
          "issues" => [ [ "conflicting", "could not inspect alias #{alias_path}: #{e.message}" ] ].freeze
        }
      end

      def runtime_issues(native_package, resolution)
        issues = []
        if native_package.nil?
          issues << [ "missing", "expected package is not installed" ]
        elsif native_package["enabled"] == false
          issues << [ "missing", "expected package is installed but disabled" ]
        end
        if resolution["status"] != "present"
          message = native_package ? "native inventory reports the package, but runtime cannot resolve the skill" : resolution["message"]
          issues << [ "missing", message ]
        end
        issues
      end

      def package_version_issues(package, native_package)
        return [] unless native_package
        version = native_package["version"].to_s
        return [] if version == "unknown" && package.version == ">= 0"
        return [ [ "incompatible", "installed package version is unavailable" ] ] if version.empty? || version == "unknown"

        installed = Gem::Version.new(version)
        return [] if package.requirement.satisfied_by?(installed)

        lower = package.requirement.requirements.filter_map do |operator, boundary|
          boundary if %w[> >= = ~>].include?(operator)
        end.min
        health = lower && installed < lower ? "stale" : "incompatible"
        [ [ health, "installed package #{version} does not satisfy #{package.version}" ] ]
      rescue ArgumentError => e
        [ [ "incompatible", "installed package version #{version.inspect} is invalid: #{e.message}" ] ]
      end

      def source_issues(native_spec, native)
        issues = []
        marketplace = native["marketplace"]
        if native_spec.marketplace
          if marketplace.nil?
            issues << [ "missing", "marketplace #{native_spec.marketplace} is not configured" ]
          elsif !same_source?(marketplace["source"], native_spec.source)
            issues << [ "conflicting", "marketplace #{native_spec.marketplace} is owned by #{marketplace['source'].inspect}, expected #{native_spec.source.inspect}" ]
          end
        end
        package_source = native.dig("package", "source")
        if package_source && !same_source?(package_source, native_spec.source)
          issues << [ "incompatible", "installed package source #{package_source.inspect} does not match #{native_spec.source.inspect}" ]
        end
        issues
      end

      def expected_resolution_path?(path, target, native)
        roots = []
        install_path = native.dig("package", "install_path")
        roots << install_path if install_path
        native_spec = @manifest.package(target.package_id).native_for(target.agent)
        config_root = config_root_for(native_spec)
        if native_spec.marketplace
          plugin = native_spec.package.split("@", 2).first
          roots << File.join(config_root, "plugins", "cache", native_spec.marketplace, plugin)
          roots << File.join(config_root, "plugins", "marketplaces", native_spec.marketplace, "plugins", plugin)
          roots << File.join(config_root, ".tmp", "marketplaces", native_spec.marketplace, "plugins", plugin)
        end
        expanded_path = File.expand_path(path)
        roots.compact.any? do |root|
          expanded_root = File.expand_path(root)
          expanded_path == expanded_root || expanded_path.start_with?(expanded_root + File::SEPARATOR)
        end
      end

      def build_inspection(target:, expected:, native:, resolution:, issues:, remediation: nil)
        selected = issues.min_by { |health, _| HEALTH_PRECEDENCE.index(health) || HEALTH_PRECEDENCE.length }
        health, explanation = selected || [ "healthy", healthy_explanation(expected, resolution) ]
        Inspection.new(
          target: target,
          expected: expected,
          native: native,
          resolution: resolution,
          health: health,
          severity: severity_for(health, target.managed),
          explanation: explanation,
          remediation: remediation || scoped_remediation(target)
        )
      end

      def healthy_explanation(expected, resolution)
        if expected["managed"] == false
          resolution["path"] ? "custom skill resolves at #{resolution['path']}" : "no managed skill is required"
        else
          "resolved #{expected['package']} at #{resolution['path']}"
        end
      end

      def severity_for(health, managed)
        return "info" if health == "healthy" || !managed
        return "warning" if health == "unavailable"
        "error"
      end

      def scoped_remediation(target)
        return nil unless target.managed
        "hive setup-agents --agent #{target.agent} --skill #{target.capability_id}"
      end

      def resolved_binary(profile)
        candidate = @environment[profile.env_bin_override_key].to_s if profile.env_bin_override_key
        candidate = profile.bin_default if candidate.nil? || candidate.empty?
        if candidate.include?(File::SEPARATOR)
          path = File.expand_path(candidate)
          return path if File.file?(path) && File.executable?(path)
          return nil
        end

        @environment.fetch("PATH", ENV.fetch("PATH", "")).split(File::PATH_SEPARATOR).each do |dir|
          path = File.join(dir, candidate)
          return path if File.file?(path) && File.executable?(path)
        end
        nil
      end

      def run(argv, commands)
        commands << argv.freeze
        @runner.call(argv, env: runner_environment, timeout: INVENTORY_TIMEOUT_SEC)
      end

      def runner_environment
        %w[HOME PATH CLAUDE_CONFIG_DIR CODEX_HOME PI_CODING_AGENT_DIR].each_with_object({}) do |key, out|
          out[key] = @environment[key] if @environment.key?(key)
        end
      end

      def skill_module(agent)
        case agent
        when "claude" then Hive::SkillCheck::Claude
        when "codex" then Hive::SkillCheck::Codex
        when "pi" then Hive::SkillCheck::Pi
        else raise Hive::ConfigError, "unsupported skill resolver for #{agent.inspect}"
        end
      end

      def parse_version(output)
        output.to_s[/\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.-]+)?/]
      end

      def package_version_from(root)
        return nil unless root && File.directory?(root)
        candidates = [
          File.join(root, ".claude-plugin", "plugin.json"),
          File.join(root, ".codex-plugin", "plugin.json"),
          File.join(root, "package.json")
        ]
        candidates.each do |path|
          next unless File.file?(path)
          version = JSON.parse(File.read(path))["version"]
          return version if version
        end
        nil
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def same_source?(actual, expected)
        normalize_source(actual) == normalize_source(expected)
      end

      def normalize_source(value)
        value.to_s.strip.sub(%r{\Ahttps://github\.com/}i, "").sub(/\.git\z/i, "").downcase
      end

      def config_root_for(native_spec)
        home = @environment["HOME"] || Dir.home
        value = @environment[native_spec.config_home].to_s
        return File.expand_path(value) unless value.empty?
        case native_spec.provider
        when "claude" then File.join(home, ".claude")
        when "codex" then File.join(home, ".codex")
        when "pi" then File.join(home, ".pi", "agent")
        end
      end

      def alias_path_for(alias_spec)
        home = @environment["HOME"] || Dir.home
        config_root = @environment["CLAUDE_CONFIG_DIR"].to_s
        config_root = File.join(home, ".claude") if config_root.empty?
        relative = alias_spec.path.delete_prefix(".claude/")
        File.join(config_root, relative)
      end

      def resolution_hash(resolution)
        {
          "status" => resolution.status.to_s,
          "path" => resolution.path,
          "message" => resolution.message,
          "candidates" => resolution.candidates,
          "parse_errors" => resolution.parse_errors
        }
      end

      def empty_resolution
        { "status" => "unavailable", "path" => nil, "message" => nil, "candidates" => [], "parse_errors" => [] }.freeze
      end

      def unavailable_native(profile)
        { "available" => false, "bin" => profile&.bin_default, "cli_version" => nil,
          "commands" => [], "package" => nil, "marketplace" => nil }.freeze
      end

      def alias_hash(alias_spec)
        alias_spec && { "path" => alias_spec.path, "target" => alias_spec.target, "owner" => alias_spec.owner }.freeze
      end

      def command_failure(result, fallback = "command failed")
        return "timed out" if result.timed_out
        return result.error unless result.error.to_s.empty?
        detail = result.stderr.to_s.lines.first.to_s.strip
        detail.empty? ? fallback : detail
      end
    end
  end
end
