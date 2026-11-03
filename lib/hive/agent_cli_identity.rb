require "json"
require "hive/secret_patterns"

module Hive
  # Advisory evidence only: launch policy and minimum-version enforcement stay
  # with the profile/runtime. Every lookup receives its own environment and cwd.
  module AgentCliIdentity
    Value = Data.define(:profile, :regime, :authority, :configured, :launch_path,
                        :effective_target, :version, :version_source, :reason,
                        :version_reason, :sandbox_executable, :command_prefix) do
      def initialize(**attributes)
        super(**attributes.transform_values { |value| AgentCliIdentity.freeze_diagnostic(value) })
      end
    end

    PACKAGES = {
      "claude" => %w[@anthropic-ai/claude-code],
      "codex" => %w[@openai/codex],
      "pi" => %w[@earendil-works/pi-coding-agent @mariozechner/pi-coding-agent],
      "grok" => %w[@vibe-kit/grok-cli],
      "opencode" => %w[opencode-ai]
    }.freeze
    BREW_NAMES = { "claude" => %w[claude-code], "codex" => %w[codex],
                   "opencode" => %w[opencode] }.freeze
    VERSION = /\A\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/

    class ProbeBudget
      def initialize(seconds: 60, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @clock = clock
        @deadline = @clock.call + seconds
      end

      def remaining
        [ @deadline - @clock.call, 0 ].max
      end
    end

    module_function

    def freeze_diagnostic(value)
      case value
      when String, Symbol then Hive::SecretPatterns.redact(value).freeze
      when Array then value.map { |item| freeze_diagnostic(item) }.freeze
      when Hash then value.transform_values { |item| freeze_diagnostic(item) }.freeze
      else value
      end
    end

    def observe(profile:, environment:, cwd:, regime: :plain, executable: nil,
                selector_environment: environment, selector_cwd: cwd,
                sandbox_executable: nil, command_prefix: [], probe: false,
                probe_allowed: true, budget: nil, runner: nil)
      configured = profile.runtime_profile.bin(env: environment)
      authority = { plain: "child_path", isolated: "isolated_selector_path",
                    managed: "prepared_runtime_binding" }.fetch(regime.to_sym)
      selected = if regime.to_sym == :isolated
        executable || isolated_executable(configured, environment: selector_environment, cwd: selector_cwd)
      elsif regime.to_sym == :managed
        executable
      else
        executable || configured
      end
      path = selected && resolve(selected, environment: environment, cwd: cwd)
      reason = if path.nil?
        regime.to_sym == :managed && executable.nil? ? "prepared_binding_unavailable" : "executable_unavailable"
      end
      target = path && File.realpath(path)
      if target && tool_manager_launcher?(target)
        target = nil
        reason = "opaque_launcher"
      end
      version, source, version_reason = filesystem_version(profile.name.to_s, target)
      if probe && path
        timeout = [ 30, (budget || ProbeBudget.new).remaining ].min
        if !probe_allowed
          version_reason = "environment_incomplete"
        elsif timeout <= 0.01
          version_reason = "probe_budget_exhausted"
        else
          result = profile.observe_version(executable: path, environment: environment,
                                           cwd: cwd, timeout: timeout, runner: runner)
          version, version_reason = result.values_at(:version, :reason)
          source = version ? "live_probe" : nil
        end
      end
      Value.new(profile: profile.name, regime: regime, authority: authority,
                configured: configured, launch_path: path, effective_target: target,
                version: version, version_source: source, reason: reason,
                version_reason: version ? nil : version_reason,
                sandbox_executable: sandbox_executable, command_prefix: command_prefix)
    rescue SystemCallError, ArgumentError
      Value.new(profile: profile.name, regime: regime, authority: authority,
                configured: configured, launch_path: nil, effective_target: nil,
                version: nil, version_source: nil, reason: "resolution_failed",
                version_reason: "version_unknown", sandbox_executable: sandbox_executable,
                command_prefix: command_prefix)
    end

    def resolve(name, environment:, cwd:)
      value = name.to_s
      candidates = if value.include?(File::SEPARATOR)
        [ File.expand_path(value, cwd) ]
      else
        environment["PATH"].to_s.split(File::PATH_SEPARATOR, -1).map do |directory|
          File.expand_path(File.join(directory.empty? ? "." : directory, value), cwd)
        end
      end
      candidates.find { |path| File.file?(path) && File.executable?(path) }
    end

    # This is the existing isolated-spawn selector. Its inputs intentionally
    # differ from the child's scrubbed environment.
    def isolated_executable(value, environment:, cwd:)
      name = value.to_s
      return name if name.include?(File::SEPARATOR)

      candidates = environment.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |directory|
        candidate = File.expand_path(File.join(directory, name), cwd)
        candidate if File.file?(candidate) && File.executable?(candidate)
      end
      first = candidates.first
      return name unless first
      return first unless tool_manager_launcher?(first)

      first_identity = File.realpath(first)
      alternatives = candidates.select do |candidate|
        File.realpath(candidate) != first_identity && !tool_manager_launcher?(candidate)
      rescue SystemCallError
        false
      end
      managed_segment = [ "mise", "installs", name ].join(File::SEPARATOR)
      alternatives.find { |candidate| candidate.include?(managed_segment) } || alternatives.first || first
    rescue SystemCallError
      name
    end

    def tool_manager_launcher?(path)
      source = File.open(path, File::RDONLY | File::NOFOLLOW) { |file| file.read(4096) }
      source.start_with?("#!") && source.match?(/\b(?:mise|asdf|rbenv)\b/)
    rescue SystemCallError
      false
    end

    def filesystem_version(profile, target)
      return [ nil, nil, "effective_target_unknown" ] unless target

      directory = File.dirname(target)
      7.times do
        cask_receipt = File.join(directory, ".metadata", "INSTALL_RECEIPT.json")
        if File.file?(cask_receipt)
          data = JSON.parse(File.read(cask_receipt, 128 * 1024))
          name = File.basename(directory)
          version = data.dig("source", "version").to_s
          owned = BREW_NAMES.fetch(profile, []).include?(name) &&
            File.basename(data.dig("source", "path").to_s).sub(/\.(rb|json)\z/, "") == name
          linked = Array(data["uninstall_artifacts"]).any? do |artifact|
            bin = artifact.is_a?(Hash) && artifact["binary"]
            bin.is_a?(Array) && bin.first.is_a?(String) && VERSION.match?(version) &&
              File.expand_path(bin.first, File.join(directory, version)) == target
          end
          return owned && linked ? [ version, "homebrew_cask_receipt", nil ] :
            [ nil, nil, "provider_metadata_mismatch" ]
        end
        manifest = File.join(directory, "package.json")
        if File.file?(manifest)
          data = JSON.parse(File.read(manifest, 128 * 1024))
          return [ nil, nil, "provider_metadata_mismatch" ] unless PACKAGES.fetch(profile, []).include?(data["name"])

          bins = data["bin"].is_a?(Hash) ? data["bin"].values : [ data["bin"] ]
          linked = bins.compact.any? do |bin|
            File.realpath(File.expand_path(bin, directory)) == target
          rescue SystemCallError
            false
          end
          return [ nil, nil, "provider_metadata_mismatch" ] unless linked && VERSION.match?(data["version"].to_s)

          return [ data["version"], "npm_manifest", nil ]
        end
        receipt = File.join(directory, "INSTALL_RECEIPT.json")
        if File.file?(receipt)
          data = JSON.parse(File.read(receipt, 128 * 1024))
          name = File.basename(File.dirname(directory))
          version = data.dig("source", "versions", "stable")
          owned = BREW_NAMES.fetch(profile, []).include?(name) &&
            File.basename(data.dig("source", "path").to_s, ".rb") == name &&
            File.basename(directory) == version &&
            target == File.join(directory, "bin", profile)
          return owned && VERSION.match?(version.to_s) ?
            [ version, "homebrew_receipt", nil ] : [ nil, nil, "provider_metadata_mismatch" ]
        end
        parent = File.dirname(directory)
        break if parent == directory

        directory = parent
      end
      if profile == "claude" && (match = target.match(%r{/\.local/share/claude/versions/([^/]+)\z})) && VERSION.match?(match[1])
        return [ match[1], "claude_native_install", nil ]
      end
      [ nil, nil, "unrecognized_install_layout" ]
    rescue JSON::ParserError, TypeError, SystemCallError
      [ nil, nil, "provider_metadata_mismatch" ]
    end
  end
end
