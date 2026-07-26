module AgentCliRuntime
  module Probe
    module_function

    def call(profile, home: nil, env: ENV)
      resolved = Profiles.resolve(profile)
      executable = resolved.bin(env:)
      installed = resolved.binary_installed?(env:)
      version = nil
      diagnostic = nil

      if installed
        begin
          version = resolved.check_version!(env:)
        rescue Error => e
          diagnostic = Redactor.diagnostic(e)
        end
      else
        diagnostic = Redactor.diagnostic(
          "#{resolved.name} binary not runnable: #{executable}"
        )
      end

      auth =
        if installed
          resolved.auth_configuration(home: home, env: env)
        else
          AuthConfiguration.new(status: :not_checked)
        end
      diagnostic ||= auth.diagnostic
      ready = installed &&
              !version.nil? &&
              auth.status != :missing

      ProbeResult.new(
        provider: resolved.name,
        ready: ready,
        installed: installed,
        executable: executable,
        version: version,
        minimum_version: resolved.min_version,
        auth_configuration: auth,
        capability_evidence: capability_evidence(
          resolved, installed: installed, version: version, auth: auth
        ),
        diagnostic: diagnostic
      )
    rescue StandardError => e
      resolved ||= Profiles.resolve(profile)
      ProbeResult.new(
        provider: resolved.name,
        ready: false,
        installed: false,
        executable: resolved.bin(env:),
        version: nil,
        minimum_version: resolved.min_version,
        auth_configuration: AuthConfiguration.new(status: :not_checked),
        capability_evidence: [],
        diagnostic: Redactor.diagnostic(e)
      )
    end

    def all(home: nil, env: ENV)
      Profiles.names.map do |provider|
        call(provider, home: home, env: env)
      end.freeze
    end

    def capability_evidence(profile, installed:, version:, auth:)
      capabilities = {
        headless: true,
        version: !version.nil?,
        auth_configuration: auth.status != :missing,
        add_directory: !profile.add_dir_flag.nil?,
        allowed_tools: profile.tool_scope_flags.key?(:allowed),
        disallowed_tools: profile.tool_scope_flags.key?(:disallowed),
        model: !profile.model_argument_builder.nil?,
        effort: !profile.effort_argument_builder.nil?,
        budget: !profile.budget_flag.nil?,
        raw_cli_arguments: profile.raw_cli_arguments_supported?
      }
      capabilities[:installation] = installed
      capabilities.map do |capability, supported|
        CapabilityEvidence.new(
          capability: capability,
          supported: supported,
          provider: profile.name,
          launcher_identity: profile.launcher_identity
        )
      end.freeze
    end
    private_class_method :capability_evidence
  end
end
