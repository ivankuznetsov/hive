require "hive/agent"
require "hive/agent_cli_identity"
require "hive/user_service/execution_environment"

module Hive
  module Commands
    class Doctor
      # Filesystem observations model the launch authorities independently.
      # A managed binding cannot be inferred without preparing an invocation.
      class AgentCliCheck
        REGIMES = %i[plain isolated managed].freeze

        def initialize(config:, project_root:, environment:, service_contexts: nil,
                       probe: false, budget: nil, runner: nil)
          @profiles = Hive::AgentProfiles.registered_names.map do |name|
            Hive::AgentProfiles.lookup(name, cfg: config)
          end
          @root = File.expand_path(project_root || Dir.pwd)
          @environment = environment.to_h
          @service_contexts = service_contexts
          @probe = probe
          @budget = budget
          @runner = runner
        end

        def rows
          # Manager reads have their own deadline. Start the probe budget only
          # when the agent observation pass begins.
          contexts = [ shell_context ] + services.reject(&:absent?)
          @budget ||= Hive::AgentCliIdentity::ProbeBudget.new
          @profiles.flat_map do |profile|
            observations = contexts.to_h do |context|
              [ context.label, REGIMES.to_h { |regime| [ regime, observe(profile, context, regime) ] } ]
            end
            contexts.flat_map do |context|
              REGIMES.map do |regime|
                identity = observations.fetch(context.label).fetch(regime)
                shell = observations.fetch("shell").fetch(regime)
                local = observations.fetch(context.label)
                comparison = compare(identity, shell)
                divergence = regime != :managed && selected_differ?(local.fetch(:isolated), local.fetch(:plain))
                comparison[:regime_divergence] = divergence
                build_row(profile, context, identity, comparison)
              end
            end
          end
        end

        # Non-agent helpers may share a name or alias with a configured CLI.
        # Compare executable identities, including hardlinks, before launching.
        def agent_executable?(path)
          candidate = file_identity(path)
          return false unless candidate

          contexts = [ shell_context ] + services.reject(&:absent?)
          contexts.any? do |context|
            @profiles.any? do |profile|
              %i[plain isolated].any? do |regime|
                configured = profile.runtime_profile.bin(env: context.environment)
                selected = regime == :plain ? configured : Hive::AgentCliIdentity.isolated_executable(
                  configured, environment: context.environment, cwd: context.cwd
                )
                resolved = Hive::AgentCliIdentity.resolve(selected, environment: context.environment, cwd: context.cwd)
                file_identity(resolved) == candidate
              end
            end
          end
        end

        private

        def shell_context
          @shell_context ||= Hive::UserService::ExecutionEnvironment::Context.new(
            label: "shell", environment: @environment, cwd: @root, cwd_provenance: :invocation,
            installation: :installed, reasons: [], sources: [], running_currency: :current
          )
        end

        def services
          @service_contexts ||= Hive::UserService::ExecutionEnvironment.new(
            project_root: @root, profiles: @profiles,
            excluded_executables: @profiles.flat_map do |profile|
              configured = profile.runtime_profile.bin(env: @environment)
              [ configured, Hive::AgentCliIdentity.isolated_executable(
                configured, environment: @environment, cwd: @root
              ) ].filter_map do |selected|
                Hive::AgentCliIdentity.resolve(selected, environment: @environment, cwd: @root)
              end
            end
          ).call
        end

        def observe(profile, context, regime)
          environment = context.environment
          if regime == :isolated
            environment = environment.slice(*Hive::Agent::ISOLATED_CHILD_ENV_KEYS)
              .merge(Hive::Agent::SCRUBBED_CHILD_ENV)
              .merge(profile.subscription_environment)
          end
          Hive::AgentCliIdentity.observe(
            profile: profile, environment: environment, cwd: context.cwd, regime: regime,
            selector_environment: context.environment, selector_cwd: context.cwd,
            probe: @probe, probe_allowed: context.probe_allowed?, budget: @budget, runner: @runner
          )
        end

        def compare(identity, shell)
          launch = relation(identity.launch_path, shell.launch_path)
          target = relation(identity.effective_target, shell.effective_target)
          version = if identity.version && shell.version
            order = version_key(identity.version) <=> version_key(shell.version)
            { -1 => "older", 0 => "same", 1 => "newer" }.fetch(order)
          else
            "unknown"
          end
          state = if launch == "different" || target == "different" || %w[older newer].include?(version)
            "drift"
          elsif identity.reason || launch == "unknown" || target == "unknown"
            "incomplete"
          elsif version == "unknown"
            "uninspected"
          else
            "match"
          end
          { state: state, launch_path: launch, effective_target: target, version: version }
        end

        def version_key(version)
          release, prerelease = version.split("+", 2).first.split("-", 2)
          identifiers = prerelease.to_s.split(".").map do |identifier|
            identifier.match?(/\A\d+\z/) ? [ 0, identifier.to_i ] : [ 1, identifier ]
          end
          [ release.split(".").map(&:to_i), prerelease ? 0 : 1, identifiers ]
        end

        def relation(left, right)
          return "unknown" unless left && right

          left == right ? "same" : "different"
        end

        def selected_differ?(left, right)
          !!(left.launch_path && right.launch_path && left.launch_path != right.launch_path)
        end

        def build_row(profile, context, identity, comparison)
          complete = comparison[:state] == "match" && !comparison[:regime_divergence] &&
            !identity.version_reason && context.complete? && %i[current stopped].include?(context.running_currency)
          remedy = "verify agents.#{profile.name}.bin and agents.#{profile.name}.min_version"
          if context.running_currency == :stale
            remedy += "; reload service configuration and restart #{context.label}"
          elsif context.running_currency == :unknown && context.label != "shell"
            remedy += "; verify loaded configuration and restart #{context.label} if needed"
          end
          remedy += "; rerun hive doctor --probe-agent-versions" if comparison[:state] == "uninspected"
          details = [
            "#{context.label} #{identity.regime} (#{identity.authority})",
            "configured=#{identity.configured}", "launcher=#{identity.launch_path || 'unavailable'}",
            "target=#{identity.effective_target || 'unknown'}",
            "version=#{identity.version || 'unknown'} evidence=#{identity.version_source || identity.version_reason}",
            "comparison=#{comparison[:state]}",
            "launch_path=#{comparison[:launch_path]} target=#{comparison[:effective_target]} version=#{comparison[:version]}"
          ]
          details << "reason=#{identity.reason}" if identity.reason
          details << "version_reason=#{identity.version_reason}" if identity.version_reason
          details << "version-uninspected; rerun hive doctor --probe-agent-versions" if comparison[:state] == "uninspected"
          details << "#{context.label} version is older than shell" if comparison[:version] == "older"
          details << "selection differs across plain and isolated regimes" if comparison[:regime_divergence]
          if context.label != "shell"
            details << "declared configuration; running_currency=#{context.running_currency}"
            details << "cwd_inherited=#{context.cwd}" if context.cwd_provenance == :inherited
          end
          context.reasons.each do |reason|
            details << [ reason[:code], reason[:path], reason[:line] ].compact.join(":")
          end
          {
            kind: complete ? "dependency" : "warning", stage: "agent_cli", label: "agent_cli/#{profile.name}",
            agent: profile.name.to_s, configured_skill: identity.configured, skill: context.label,
            status: complete ? "present" : "warning", message: details.join("; "), remediation: remedy,
            regime: identity.regime, identity: identity.to_h, comparison: comparison,
            execution_context: {
              installation: context.installation.to_s, cwd: context.cwd, cwd_provenance: context.cwd_provenance.to_s,
              complete: context.complete?, running_currency: context.running_currency.to_s,
              reasons: context.reasons, sources: context.sources
            }
          }
        end

        def file_identity(path)
          return unless path

          stat = File.stat(path)
          [ stat.dev, stat.ino ] if stat.file?
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
