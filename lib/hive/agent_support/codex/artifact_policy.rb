require "json"

module Hive::AgentSupport::Codex::ArtifactPolicy
  PERMISSION_PROFILE = "hive-evidence".freeze
  MINIMUM_VERSION = "0.147.0".freeze

  module_function

  def prepare(profile:, runtime_resolver: nil, task_root:, source_root:, writable_root:,
              mailbox_root:, extra_read_paths:, hive_runtime_paths:, **)
    resolver = runtime_resolver || method(:runtime_roots)
    roots = Array(resolver.call(profile))
    filesystem = {
      ":minimal" => "read", task_root => "read", source_root => "read",
      writable_root => "write", mailbox_root => "write"
    }
    (extra_read_paths + roots + hive_runtime_paths).each do |path|
      filesystem[path] = "read"
    end
    mapping = filesystem.map do |path, access|
      "#{JSON.generate(path)}=#{JSON.generate(access)}"
    end.join(",")
    {
      permission_arguments: [
        "--ephemeral", "--ignore-user-config", "--ignore-rules",
        "--enable", "network_proxy",
        "-c", 'approval_policy="never"',
        "-c", "default_permissions=#{JSON.generate(PERMISSION_PROFILE)}",
        "-c", "permissions.#{PERMISSION_PROFILE}.filesystem={#{mapping}}",
        "-c", "permissions.#{PERMISSION_PROFILE}.network.enabled=true",
        "-c", "permissions.#{PERMISSION_PROFILE}.network.mode=\"limited\"",
        "-c", "permissions.#{PERMISSION_PROFILE}.network.allow_local_binding=true",
        "-c", "permissions.#{PERMISSION_PROFILE}.network.domains={}",
        "-c", 'web_search="disabled"',
        *Hive::AgentSupport::Codex::Runtime::ISOLATION_ARGUMENTS
      ].freeze,
      runtime_policy: nil
    }.freeze
  end

  def runtime_roots(profile)
    unless profile&.name == :codex
      raise Hive::ConfigError, "managed capture evidence requires the Codex producer"
    end

    compatible = profile.with_overrides("min_version" => MINIMUM_VERSION)
    compatible.check_version!
    runtime = Hive::AgentSupport::Codex::Runtime
    executable = runtime.executable(
      host: Hive::WorkflowPackage::RuntimePolicy::ProviderHost, profile: compatible
    )
    [ runtime.runtime_root(executable) ]
  rescue Hive::AgentError => error
    raise Hive::ConfigError,
          "managed capture evidence requires Codex #{MINIMUM_VERSION}+: #{error.message}"
  rescue Errno::ENOENT, Errno::EACCES
    raise Hive::ConfigError,
          "managed capture evidence could not resolve the Codex native runtime"
  end
end
