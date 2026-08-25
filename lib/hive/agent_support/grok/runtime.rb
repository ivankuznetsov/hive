require "json"
require "tmpdir"

module Hive::AgentSupport::Grok::Runtime
  SANDBOX_PATH = "/usr/bin/bwrap".freeze

  module_function

  def compile_managed_actor(host:, scope:, task_root:, directories:, profile:, environment:,
                            outputs:, runtime_root:, tool_names:, prepare:)
    unless prepare
      return host.portable_admission_policy(scope, task_root:, directories:, environment:)
    end
    unless File.file?(SANDBOX_PATH) && File.executable?(SANDBOX_PATH)
      raise Hive::ConfigError, "runner :grok requires bubblewrap for managed workflow isolation"
    end

    executable = host.resolve_profile_executable(profile)
    auth_path = Hive::AgentSupport::Grok.credential_path
    unless File.file?(auth_path)
      raise Hive::ConfigError, "runner :grok managed workflow auth file is unavailable"
    end

    runtime_home = runtime_root || Dir.mktmpdir("hive-managed-grok-")
    visible_tools = tool_names - host::PORTABLE_HOST_OUTPUT_TOOLS
    flags = [
      "--sandbox", "read-only", "--permission-mode", "dontAsk",
      "--tools", visible_tools.join(","),
      "--deny", "Read(/auth/**)", "--deny", "Grep(/auth/**)",
      "--deny", "Glob(/auth/**)", "--deny", "Read(/proc/**)",
      "--deny", "Grep(/proc/**)", "--deny", "Glob(/proc/**)",
      "--no-memory", "--no-subagents", "--verbatim"
    ]
    flags << "--disable-web-search" if (visible_tools & host::PORTABLE_NETWORK_TOOLS).empty?
    flags.concat([ "--json-schema", JSON.generate(host.output_schema(outputs.keys)) ]) unless outputs.empty?
    child_environment = environment.merge(
      "HOME" => "/runtime-home", "GROK_HOME" => "/runtime-home/.grok",
      "GROK_AUTH_PATH" => "/auth/auth.json", "PATH" => "/usr/local/bin"
    ).freeze
    prefix = bwrap_prefix(
      host:, executable:, auth_path:, runtime_home:, directories:, cwd: task_root
    )

    host.portable_policy(
      scope, task_root:, directories:, environment: child_environment, outputs:,
      runtime_root: runtime_home, cli_flags: flags, executable: "/usr/local/bin/grok",
      command_prefix: prefix
    )
  end

  def bwrap_prefix(host:, executable:, auth_path:, runtime_home:, directories:, cwd:)
    parents = host.sandbox_parent_dirs(
      directories + [ cwd ],
      excluded: %w[/tmp /usr /usr/local /usr/local/bin /etc /proc /dev /auth /runtime-home]
    )
    prefix = [
      SANDBOX_PATH,
      "--die-with-parent", "--new-session", "--unshare-all", "--share-net",
      "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
      "--dir", "/usr", "--dir", "/usr/local", "--dir", "/usr/local/bin",
      "--ro-bind", executable, "/usr/local/bin/grok",
      "--dir", "/etc", "--ro-bind", "/etc/ssl", "/etc/ssl",
      "--ro-bind", "/etc/resolv.conf", "/etc/resolv.conf",
      "--ro-bind", "/etc/hosts", "/etc/hosts",
      "--dir", "/auth", "--ro-bind", auth_path, "/auth/auth.json",
      "--bind", runtime_home, "/runtime-home"
    ]
    prefix.concat(parents.flat_map { |path| [ "--dir", path ] })
    prefix.concat(directories.uniq.flat_map { |path| [ "--ro-bind", path, path ] })
    prefix.concat([
      "--setenv", "HOME", "/runtime-home",
      "--setenv", "GROK_HOME", "/runtime-home/.grok",
      "--setenv", "GROK_AUTH_PATH", "/auth/auth.json",
      "--setenv", "PATH", "/usr/local/bin", "--chdir", cwd, "--"
    ])
  end
  private_class_method :bwrap_prefix
end
