require "json"
require "rubygems/version"

require "hive/agent_skills"
require "hive/agent_skills/command_runner"
require "hive/agent_skills/filesystem_inventory"
require "hive/agent_skills/manifest"
require "hive/agent_skills/target_resolver"
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

    # Shared health model used by doctor and setup. Doctor selects durable
    # filesystem evidence; consented setup selects refreshed native inventory.
    # A row is healthy only when SkillCheck resolves the exact runtime
    # invocation from the expected package (or Hive-owned alias).
    class Inspector
      HEALTH_PRECEDENCE = %w[conflicting incompatible unavailable stale missing healthy].freeze
      INVENTORY_TIMEOUT_SEC = 10

      def initialize(config:, project_root:, manifest: Manifest.load,
                     resolver: nil, runner: CommandRunner.new, environment: ENV,
                     include_openclaw: false, openclaw_adapter: nil,
                     native_commands: true)
        @config = config
        @project_root = project_root && File.expand_path(project_root)
        @manifest = manifest
        @resolver = resolver || TargetResolver.new(
          config: config, project_root: @project_root, manifest: manifest
        )
        @runner = runner
        @environment = environment
        @include_openclaw = include_openclaw
        @openclaw_adapter = openclaw_adapter
        @native_commands = native_commands
        @native_cache = {}
      end

      def inspect(agents: nil, skills: nil)
        # Inventory is deduplicated only within one inspection pass. Setup's
        # post-provision verification must observe fresh native state rather
        # than the pre-execution cache.
        @native_cache = {}
        @filesystem_inventory = FilesystemInventory.new unless @native_commands
        rows = @resolver.resolve(agents: agents, skills: skills).map { |target| inspect_target(target) }
        rows << inspect_openclaw if @include_openclaw && Array(agents).empty? && Array(skills).empty?
        rows.freeze
      end

      private

      def inspect_openclaw
        require "hive/agent_skills/adapters/openclaw"
        evidence = (@openclaw_adapter || Adapters::OpenClaw.new(
          environment: @environment
        )).inspect
        target = Target.new(
          surfaces: [ "hive.operations" ].freeze,
          kind: "openclaw",
          agent: "openclaw",
          configured_skill: "hive",
          invocation: evidence.expected.fetch("invocation"),
          capability_id: "hive",
          package_id: "hive-operations",
          managed: false
        ).freeze
        Inspection.new(
          target: target,
          expected: evidence.expected,
          native: evidence.native,
          resolution: evidence.resolution,
          health: evidence.health,
          severity: evidence.health == "healthy" ? "info" : "warning",
          explanation: evidence.explanation,
          remediation: evidence.remediation
        ).freeze
      end

      def inspect_target(target)
        return inspect_unmanaged(target) unless target.managed

        capability = @manifest.capability(target.capability_id)
        package = @manifest.package(capability.package_id)
        contract = capability.agent(target.agent)
        return inspect_bundled_target(target, package, contract) if package.bundled?

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
          profile: profile, bin: bin, native_spec: native_spec
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
          native: native.reject { |key, _| %w[issues runtime_skills].include?(key) }.freeze,
          resolution: resolution.reject { |key, _| key == "issues" }.freeze,
          issues: issues
        )
      end

      def inspect_bundled_target(target, package, contract)
        bundled_spec = package.native_for(target.agent)
        projection = Hive::AgentSkills.render(target.agent)
        root = config_root_for(bundled_spec)
        destination = File.join(root, projection.destination_relative)
        expected = {
          "distribution" => "bundled",
          "package" => package.id,
          "package_id" => package.id,
          "version" => projection.skill_version,
          "canonical_digest" => projection.canonical_digest,
          "source" => "hive-gem",
          "marketplace" => nil,
          "destination" => destination,
          "invocation" => contract.invocation,
          "probe" => contract.probe,
          "files" => projection.files.keys.sort.to_h do |path|
            [ path, ::Digest::SHA256.hexdigest(projection.files.fetch(path)) ]
          end.freeze,
          "alias" => nil
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

        report = Hive::AgentSkills.inspect(
          root: root,
          trusted_root: @environment["HOME"] || Dir.home,
          projection: projection
        )
        cli = inspect_bundled_cli(profile: profile, bin: bin)
        resolution = inspect_bundled_resolution(target, contract, destination)
        issues = cli.fetch("issues").map(&:dup)
        issues.concat(report.issues)
        issues.concat(resolution.fetch("issues"))
        native_package = if report.manifest
          {
            "id" => package.id,
            "version" => report.manifest["skill_version"],
            "enabled" => true,
            "install_path" => destination,
            "source" => "hive-gem",
            "canonical_digest" => report.manifest["canonical_digest"]
          }.freeze
        end
        native = cli.reject { |key, _| key == "issues" }.merge(
          "package" => native_package,
          "marketplace" => nil,
          "projection" => {
            "state" => report.state,
            "destination" => report.destination,
            "manifest" => report.manifest,
            "files" => report.files,
            "snapshot" => report.snapshot
          }.freeze
        ).freeze

        build_inspection(
          target: target,
          expected: expected,
          native: native,
          resolution: resolution.reject { |key, _| key == "issues" }.freeze,
          issues: issues
        )
      rescue DirectoryPublisher::Error => e
        build_inspection(
          target: target,
          expected: expected || { "distribution" => "bundled", "package" => package.id }.freeze,
          native: { "available" => true, "bin" => bin, "cli_version" => nil,
                    "commands" => [], "package" => nil, "marketplace" => nil }.freeze,
          resolution: empty_resolution,
          issues: [ [ "conflicting", e.message ] ]
        )
      end

      def inspect_bundled_cli(profile:, bin:)
        unless @native_commands
          return {
            "available" => true,
            "bin" => bin,
            "cli_version" => nil,
            "commands" => [].freeze,
            "inventory_source" => "filesystem",
            "issues" => [].freeze
          }.freeze
        end

        commands = []
        issues = []
        version_result = run([ bin, profile.version_flag ], commands)
        version = parse_version(version_result.stdout)
        unless version_result.success? && version
          issues << [ "incompatible", "#{profile.name} CLI version probe failed: #{command_failure(version_result, 'version output was not parseable')}" ]
        end
        if version && profile.min_version && Gem::Version.new(version) < Gem::Version.new(profile.min_version)
          issues << [ "incompatible", "#{profile.name} CLI #{version} is below supported #{profile.min_version}" ]
        end
        {
          "available" => true,
          "bin" => bin,
          "cli_version" => version,
          "commands" => commands.freeze,
          "issues" => issues.freeze
        }
      end

      def inspect_bundled_resolution(target, contract, destination)
        resolved = skill_module(target.agent).resolve(
          contract.invocation, project_root: @project_root, environment: @environment
        )
        expected_path = File.join(destination, "SKILL.md")
        issues = []
        if resolved.path && File.expand_path(resolved.path) != File.expand_path(expected_path)
          issues << [ "conflicting", "unexpected higher-precedence skill #{resolved.path} wins #{target.invocation}" ]
        elsif resolved.status != :present && File.directory?(destination)
          issues << [ "missing", "installed Hive operating skill does not resolve for #{target.invocation}" ]
        end
        resolution_hash(resolved).merge(
          "invocation" => contract.invocation,
          "alias_path" => nil,
          "alias_owned" => nil,
          "issues" => issues.freeze
        )
      rescue SystemCallError => e
        {
          "status" => "missing", "path" => nil, "message" => e.message,
          "candidates" => [], "parse_errors" => [], "invocation" => contract.invocation,
          "alias_path" => nil, "alias_owned" => nil,
          "issues" => [ [ "conflicting", "could not inspect bundled skill resolution: #{e.message}" ] ].freeze
        }
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
          resolver = begin
            skill_module(target.agent)
          rescue Hive::ConfigError => e
            return build_inspection(
              target: target,
              expected: { "managed" => false }.freeze,
              native: { "available" => true, "bin" => bin }.freeze,
              resolution: {
                "status" => "unsupported", "path" => nil,
                "message" => e.message, "candidates" => [], "parse_errors" => []
              }.freeze,
              issues: [ [ "unavailable", e.message ] ],
              remediation: "install or configure #{target.configured_skill.inspect} manually; Hive does not manage custom skills"
            )
          end
          resolved = resolver.resolve(
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

      def inspect_native(profile:, bin:, native_spec:)
        unless @native_commands
          return @filesystem_inventory.inspect(
            profile: profile,
            bin: bin,
            native_spec: native_spec,
            root: config_root_for(native_spec)
          )
        end

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
        when "grok" then grok_inventory(bin, native_spec, commands, issues)
        else
          issues << [ "incompatible", "unsupported provider #{native_spec.provider.inspect}" ]
          { "package" => nil, "marketplace" => nil }
        end

        evidence = {
          "available" => true,
          "bin" => bin,
          "cli_version" => version,
          "commands" => commands.freeze,
          "package" => inventory.fetch("package"),
          "marketplace" => inventory.fetch("marketplace"),
          "issues" => issues.freeze
        }
        evidence["runtime_skills"] = inventory.fetch("runtime_skills") if inventory.key?("runtime_skills")
        evidence
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

      def grok_inventory(bin, native_spec, commands, issues)
        plugins_result = run([ bin, "plugin", "list", "--json" ], commands)
        inspect_result = run([ bin, "inspect", "--json" ], commands, chdir: @project_root)
        issues << [ "incompatible", "grok plugin inventory failed: #{command_failure(plugins_result)}" ] unless plugins_result.success?
        issues << [ "incompatible", "grok runtime inspection failed: #{command_failure(inspect_result)}" ] unless inspect_result.success?
        plugins = JSON.parse(plugins_result.stdout)
        runtime = JSON.parse(inspect_result.stdout)
        runtime_plugins = runtime.fetch("plugins")
        runtime_skills = runtime.fetch("skills")
        raise TypeError, "grok plugin list must be an Array" unless plugins.is_a?(Array)
        raise TypeError, "grok runtime plugins must be an Array" unless runtime_plugins.is_a?(Array)
        raise TypeError, "grok runtime skills must be an Array" unless runtime_skills.is_a?(Array)
        validate_object_entries!(plugins, "grok plugin list")
        validate_object_entries!(runtime_plugins, "grok runtime plugins")
        validate_object_entries!(runtime_skills, "grok runtime skills")

        plugin = plugins.find do |entry|
          entry["status"] == "installed" && entry["name"] == native_spec.package
        end
        runtime_plugin = runtime_plugins.find { |entry| entry["name"] == native_spec.package }
        if plugin && runtime_plugin && plugin["path"] && runtime_plugin["path"] &&
           canonical_path(plugin["path"]) != canonical_path(runtime_plugin["path"])
          issues << [
            "conflicting",
            "grok runtime plugin #{native_spec.package} resolves from #{runtime_plugin['path'].inspect}, " \
              "expected installed package #{plugin['path'].inspect}"
          ]
        end
        {
          "package" => plugin && {
            "id" => plugin["name"],
            "version" => plugin["version"],
            "enabled" => runtime_plugin ? runtime_plugin.fetch("enabled", true) : false,
            "install_path" => plugin["path"],
            "source" => plugin["source"]
          }.freeze,
          "marketplace" => nil,
          "runtime_skills" => runtime_skills.map do |entry|
            source = entry["source"]
            raise TypeError, "grok runtime skill source must be an object" unless source.is_a?(Hash)

            {
              "name" => entry["name"],
              "source_path" => source["path"]
            }.freeze
          end.freeze
        }
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
        issues.concat(grok_runtime_skill_issues(invocation, path, target, native)) if target.agent == "grok"
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
        if native["package"] && package_source.nil? && native_spec.marketplace.nil?
          issues << [ "incompatible", "installed package source is unavailable" ]
        elsif package_source && !same_source?(package_source, native_spec.source)
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
        expanded_path = canonical_path(path)
        roots.compact.any? do |root|
          expanded_root = canonical_path(root)
          expanded_path == expanded_root || expanded_path.start_with?(expanded_root + File::SEPARATOR)
        end
      end

      def grok_runtime_skill_issues(invocation, resolved_path, target, native)
        runtime_skills = native["runtime_skills"]
        return [] unless runtime_skills

        skill_name = Hive::SkillCheck.parse(invocation).name
        runtime_skill = runtime_skills.find { |entry| entry["name"] == skill_name }
        unless runtime_skill
          return [ [ "conflicting", "grok runtime does not report skill #{skill_name.inspect}" ] ]
        end

        source_path = runtime_skill["source_path"]
        unless source_path && expected_resolution_path?(source_path, target, native)
          return [ [
            "conflicting",
            "grok runtime skill #{skill_name} resolves from #{source_path.inspect}, outside the expected installed package"
          ] ]
        end
        return [] unless resolved_path && canonical_path(source_path) != canonical_path(resolved_path)

        [ [
          "conflicting",
          "grok runtime skill #{skill_name} resolves from #{source_path.inspect}, expected #{resolved_path.inspect}"
        ] ]
      end

      def validate_object_entries!(entries, label)
        return if entries.all? { |entry| entry.is_a?(Hash) }

        raise TypeError, "#{label} entries must be objects"
      end

      def canonical_path(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
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

      def run(argv, commands, chdir: nil)
        commands << argv.freeze
        options = { env: runner_environment, timeout: INVENTORY_TIMEOUT_SEC }
        options[:chdir] = chdir if chdir
        @runner.call(argv, **options)
      end

      def runner_environment
        %w[HOME PATH CLAUDE_CONFIG_DIR CODEX_HOME PI_CODING_AGENT_DIR GROK_HOME].each_with_object({}) do |key, out|
          out[key] = @environment[key] if @environment.key?(key)
        end
      end

      def skill_module(agent)
        case agent
        when "claude" then Hive::SkillCheck::Claude
        when "codex" then Hive::SkillCheck::Codex
        when "pi" then Hive::SkillCheck::Pi
        when "grok" then Hive::SkillCheck::Grok
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
          File.join(root, ".grok-plugin", "plugin.json"),
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
        Hive::AgentSkills.same_source?(actual, expected)
      end

      def config_root_for(native_spec)
        home = @environment["HOME"] || Dir.home
        value = @environment[native_spec.config_home].to_s
        return File.expand_path(value) unless value.empty?
        case native_spec.provider
        when "claude" then File.join(home, ".claude")
        when "codex" then File.join(home, ".codex")
        when "pi" then File.join(home, ".pi", "agent")
        when "grok" then File.join(home, ".grok")
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
