require "json"
require "tmpdir"
require "timeout"
require "hive/permission_scope"

module Hive::AgentSupport::Codex::Runtime
  PERMISSION_PROFILE = "hive-managed".freeze
  DOCTOR_TIMEOUT_SEC = 30
  PATH_QUALIFIED_READS = true
  ISOLATION_ARGUMENTS = [
    "-c", "mcp_servers={}",
    "-c", "apps._default.enabled=false",
    "-c", "features.apps=false",
    "-c", "features.remote_plugin=false",
    "-c", "features.tool_search=false",
    "-c", "features.multi_agent=false",
    "-c", "features.memories=false",
    "-c", "features.hooks=false",
    "-c", "features.plugins=false"
  ].freeze

  module_function

  def compile_managed_actor(host:, scope:, task_root:, directories:, profile:,
                            environment:, outputs:, runtime_root:, tool_names:, prepare:)
    read_paths = qualified_read_paths(
      scope.allowed_tools, task_root:, allowed_roots: directories, prepare:
    )
    unless prepare
      return host.portable_admission_policy(
        scope, task_root:, directories:, environment:
      )
    end

    executable = executable(host:, profile:)
    runtime_read_root = runtime_root(executable)
    schema_path = nil
    unless outputs.empty?
      schema_path = File.join(runtime_root, "output-schema.json")
      host.write_output_schema(schema_path, outputs.keys)
    end
    paths = (read_paths.empty? ? directories : read_paths) + [ runtime_read_root ]
    paths << runtime_root if runtime_root
    filesystem = ([ [ ":minimal", "read" ] ] + paths.uniq.map { |path| [ path, "read" ] })
      .map { |path, access| "#{JSON.generate(path)}=#{JSON.generate(access)}" }.join(",")
    flags = [
      "--ephemeral", "--ignore-user-config", "--ignore-rules",
      "-c", 'approval_policy="never"',
      "-c", "default_permissions=#{JSON.generate(PERMISSION_PROFILE)}",
      "-c", "permissions.#{PERMISSION_PROFILE}.filesystem={#{filesystem}}",
      "-c", "permissions.#{PERMISSION_PROFILE}.network.enabled=false",
      "-c", "web_search=#{JSON.generate((tool_names & host::PORTABLE_NETWORK_TOOLS).any? ? 'live' : 'disabled')}",
      *ISOLATION_ARGUMENTS
    ]
    flags.concat([ "--output-schema", schema_path ]) if schema_path
    host.portable_policy(
      scope, task_root:, directories:, environment:, outputs:, runtime_root:,
      cli_flags: flags, executable:
    )
  end

  def qualified_read_paths(rules, task_root:, allowed_roots:, prepare:)
    selected = Array(rules).filter_map do |rule|
      match = Hive::PermissionScope::TOOL_RULE_PATTERN.match(rule.to_s.strip)
      rule if match && match[:tool] == "Read" && match[:specifier]
    end
    roots = allowed_roots.map { |root| File.realpath(root) }
    selected.map do |rule|
      raw = Hive::PermissionScope::TOOL_RULE_PATTERN
        .match(rule.to_s.strip)[:specifier].sub(%r{\A//}, "/")
      if raw.include?("*")
        raise Hive::ConfigError,
              "runner :codex cannot enforce wildcard path-qualified Read rule #{rule.inspect}"
      end
      expanded = File.absolute_path?(raw) ? File.expand_path(raw) : File.expand_path(raw, task_root)
      unless roots.any? { |root| contained?(expanded, root) }
        raise Hive::ConfigError,
              "runner :codex path-qualified Read rule escapes declared roots: #{rule.inspect}"
      end
      next expanded unless prepare

      resolved = File.realpath(expanded)
      unless roots.any? { |root| contained?(resolved, root) }
        raise Hive::ConfigError,
              "runner :codex path-qualified Read rule resolves outside declared roots: #{rule.inspect}"
      end
      resolved
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
      raise Hive::ConfigError,
            "runner :codex path-qualified Read target is unavailable: #{rule.inspect}"
    end.uniq.freeze
  end

  def executable(host:, profile:)
    configured = profile.bin
    if configured.include?(File::SEPARATOR) && File.file?(configured) && File.executable?(configured)
      return File.realpath(configured)
    end

    @executables ||= {}
    @executables[configured] ||= begin
      stdout, stderr, status = doctor(host, configured)
      report = JSON.parse(stdout)
      candidate = report.dig("checks", "runtime.provenance", "details", "current executable")
      if candidate.is_a?(String) && File.absolute_path?(candidate) &&
         File.file?(candidate) && File.executable?(candidate)
        File.realpath(candidate)
      elsif status.success?
        raise Hive::ConfigError, "runner :codex reported an unavailable managed executable"
      else
        raise Hive::ConfigError, doctor_failure(stderr)
      end
    rescue JSON::ParserError
      raise Hive::ConfigError, status&.success? ?
        "runner :codex returned malformed doctor output" : doctor_failure(stderr)
    rescue Timeout::Error
      raise Hive::ConfigError,
            "runner :codex managed executable probe timed out after #{DOCTOR_TIMEOUT_SEC}s"
    rescue Errno::ENOENT, Errno::EACCES
      raise Hive::ConfigError, "runner :codex reported an unavailable managed executable"
    end
  end

  def doctor(host, configured)
    Dir.mktmpdir("hive-codex-doctor-") do |probe_home|
      host.capture3_bounded(
        configured, "doctor", "--json", timeout_sec: DOCTOR_TIMEOUT_SEC,
        environment: { "CODEX_HOME" => probe_home, "MISE_QUIET" => "1" }
      )
    end
  end

  def doctor_failure(stderr)
    detail = stderr.to_s.strip[0, 160]
    detail = "doctor exited unsuccessfully without diagnostics" if detail.empty?
    "runner :codex could not resolve its managed executable: #{detail}"
  end

  def runtime_root(executable)
    root = File.dirname(File.dirname(executable))
    return File.dirname(executable) unless
      File.directory?(File.join(root, "codex-resources")) &&
      File.directory?(File.join(root, "codex-path"))

    root
  end

  def contained?(path, root)
    path == root || path.start_with?(root + File::SEPARATOR)
  end
  private_class_method :qualified_read_paths, :doctor, :doctor_failure, :contained?
end
