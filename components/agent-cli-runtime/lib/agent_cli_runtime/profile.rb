require "open3"
require "timeout"
require "rubygems/version"

module AgentCliRuntime
  class Profile
    PROMPT_STYLES = %i[positional headless_flag_value stdin].freeze
    WORKSPACE_WRITE_PERMISSION_MODE = "workspace-write".freeze
    READ_ONLY_PERMISSION_MODE = "read-only".freeze
    CAPTURE_TIMEOUT_SECONDS = 10
    CAPTURE_POLL_SECONDS = 0.01
    CAPTURE_TERM_GRACE_SECONDS = 0.2

    attr_reader :name, :bin_default, :env_bin_override_keys, :headless_flag,
                :permission_skip_flag, :workspace_write_flags,
                :read_only_flags, :add_dir_flag, :tool_scope_flags,
                :budget_flag, :output_format_flags, :version_flag,
                :min_version, :prompt_style, :model_argument_builder,
                :effort_argument_builder, :launcher_identity,
                :cli_capabilities

    def initialize(name:, bin_default:, headless_flag:, version_flag:,
                   env_bin_override_keys: [], permission_skip_flag: nil,
                   workspace_write_flags: [], read_only_flags: [],
                   add_dir_flag: nil, tool_scope_flags: {}, budget_flag: nil,
                   output_format_flags: [], min_version: nil,
                   prompt_style: :positional, model_argument_builder: nil,
                   effort_argument_builder: nil, launcher_identity: nil,
                   usage_extractor: nil, auth_configuration_probe: nil,
                   cli_capabilities: {}, raw_cli_arguments_supported: false)
      normalized_prompt_style = prompt_style.to_sym
      unless PROMPT_STYLES.include?(normalized_prompt_style)
        raise ArgumentError,
              "unknown prompt_style #{prompt_style.inspect}; valid: #{PROMPT_STYLES.inspect}"
      end

      @name = name.to_sym
      @bin_default = immutable_string(bin_default)
      @env_bin_override_keys = immutable_strings(env_bin_override_keys)
      @headless_flag = immutable_string(headless_flag)
      @permission_skip_flag =
        permission_skip_flag.nil? ? nil : immutable_string(permission_skip_flag)
      @workspace_write_flags = immutable_strings(workspace_write_flags)
      @read_only_flags = immutable_strings(read_only_flags)
      @add_dir_flag = add_dir_flag.nil? ? nil : immutable_string(add_dir_flag)
      @tool_scope_flags = normalize_tool_scope_flags(tool_scope_flags)
      @budget_flag = budget_flag.nil? ? nil : immutable_string(budget_flag)
      @output_format_flags = immutable_strings(output_format_flags)
      @version_flag = immutable_string(version_flag)
      @min_version = min_version.nil? ? nil : immutable_string(min_version)
      @prompt_style = normalized_prompt_style
      @model_argument_builder = model_argument_builder
      @effort_argument_builder = effort_argument_builder
      @launcher_identity =
        immutable_string(launcher_identity || "agent-cli-runtime/v1:#{@name}")
      @usage_extractor = usage_extractor || ->(_event) { nil }
      @auth_configuration_probe = auth_configuration_probe
      @cli_capabilities = normalize_cli_capabilities(cli_capabilities)
      @raw_cli_arguments_supported = raw_cli_arguments_supported == true
      freeze
    end

    def bin(env: ENV)
      key = @env_bin_override_keys.find do |candidate|
        !env[candidate].to_s.empty?
      end
      key ? env.fetch(key) : @bin_default
    end

    def permission_flags(permission_mode = nil)
      if permission_mode == WORKSPACE_WRITE_PERMISSION_MODE
        return @workspace_write_flags.dup unless @workspace_write_flags.empty?

        raise ArgumentError,
              "agent profile #{@name.inspect} cannot enforce workspace-write sandboxing"
      end
      if permission_mode == READ_ONLY_PERMISSION_MODE
        return @read_only_flags.dup unless @read_only_flags.empty?

        raise ArgumentError,
              "agent profile #{@name.inspect} cannot enforce read-only sandboxing"
      end
      return [] unless @permission_skip_flag
      return [ @permission_skip_flag ] unless @name == :claude && permission_mode
      return [ @permission_skip_flag ] if permission_mode == "bypassPermissions"

      [ "--permission-mode", permission_mode.to_s ]
    end

    def identity_arguments(model:, effort:, pin_model: true)
      normalized_model = nonempty_value(model, "model")
      normalized_effort = effort.nil? ? nil : nonempty_value(effort, "effort")
      native_arguments = []
      if pin_model
        unless @model_argument_builder
          raise UnsupportedCapability,
                "agent profile #{@name.inspect} cannot pin a model"
        end
        native_arguments.concat(@model_argument_builder.call(normalized_model))
      end

      effective_effort = nil
      if normalized_effort
        unless @effort_argument_builder
          raise UnsupportedCapability,
                "agent profile #{@name.inspect} cannot set reasoning effort"
        end
        native_arguments.concat(@effort_argument_builder.call(normalized_effort))
        effective_effort = normalized_effort
      end

      IdentityArguments.new(
        model: normalized_model,
        requested_effort: normalized_effort,
        effective_effort: effective_effort,
        effort_supported: !@effort_argument_builder.nil?,
        model_pinned: pin_model,
        native_arguments: validate_arguments(native_arguments)
      )
    end

    def raw_cli_arguments_supported?
      @raw_cli_arguments_supported
    end

    def binary_installed?(env: ENV)
      executable = bin(env:)
      return File.file?(executable) && File.executable?(executable) if executable.include?(File::SEPARATOR)

      env.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
        candidate = File.join(directory, executable)
        File.file?(candidate) && File.executable?(candidate)
      end
    rescue ArgumentError
      false
    end

    def check_version!(env: ENV)
      executable = bin(env:)
      out, _err, status = bounded_capture3(
        executable, @version_flag, timeout_sec: CAPTURE_TIMEOUT_SECONDS
      )
      unless status.success?
        raise BinaryUnavailable,
              "#{@name} binary not runnable: #{executable}"
      end

      version = out[/\d+\.\d+\.\d+/]
      unless version
        raise VersionError,
              "could not parse #{@name} #{@version_flag} output"
      end
      if @min_version &&
         Gem::Version.new(version) < Gem::Version.new(@min_version)
        raise VersionError,
              "#{@name} #{version} below minimum #{@min_version}"
      end
      version.freeze
    rescue Errno::ENOENT, Errno::EACCES => e
      raise BinaryUnavailable,
            "#{@name} binary not runnable: #{executable} (#{e.class.name.split('::').last})"
    rescue Timeout::Error
      raise BinaryUnavailable,
            "#{@name} version check timed out after #{CAPTURE_TIMEOUT_SECONDS}s: #{executable}"
    end

    def auth_configuration(home: nil, env: ENV)
      return AuthConfiguration.new(status: :not_checked) unless @auth_configuration_probe

      result = @auth_configuration_probe.call(home: home, env: env)
      return result if result.is_a?(AuthConfiguration)

      raise TypeError,
            "auth_configuration_probe must return AgentCliRuntime::AuthConfiguration"
    rescue StandardError => e
      AuthConfiguration.new(
        status: :missing,
        diagnostic: Redactor.diagnostic(e)
      )
    end

    def extract_usage_event(event)
      @usage_extractor.call(event)
    rescue StandardError
      nil
    end

    def require_cli_capability!(capability)
      capability_name = capability.to_sym
      flags = @cli_capabilities[capability_name]
      unless flags
        raise UnsupportedCapability,
              "agent profile #{@name.inspect} does not declare CLI capability " \
              "#{capability_name.inspect}"
      end

      help = capture_help(flags)
      missing = flags.grep(/\A-/).reject { |flag| flag_advertised?(help, flag) }
      unless missing.empty?
        raise UnsupportedCapability,
              "#{@name} does not advertise required #{capability_name} capability " \
              "(missing #{missing.join(', ')})"
      end
      flags.dup
    end

    private

    def immutable_string(value)
      value.to_s.dup.freeze
    end

    def immutable_strings(values)
      Array(values).map { |value| immutable_string(value) }.freeze
    end

    def normalize_tool_scope_flags(flags)
      unless flags.is_a?(Hash)
        raise ArgumentError, "tool_scope_flags must be a Hash"
      end

      flags.each_with_object({}) do |(scope, flag), normalized|
        name = scope.to_sym
        unless %i[allowed disallowed].include?(name)
          raise ArgumentError, "unknown tool scope #{scope.inspect}"
        end
        normalized[name] = nonempty_value(flag, "tool scope flag")
      end.freeze
    end

    def normalize_cli_capabilities(capabilities)
      unless capabilities.is_a?(Hash)
        raise ArgumentError, "cli_capabilities must be a Hash"
      end

      capabilities.each_with_object({}) do |(name, flags), normalized|
        values = immutable_strings(flags)
        raise ArgumentError, "CLI capability #{name.inspect} is empty" if values.empty?

        normalized[name.to_sym] = values
      end.freeze
    end

    def nonempty_value(value, label)
      string = value.to_s
      if string.empty? || string.include?("\0")
        raise ArgumentError, "#{label} must be a non-empty string without NUL bytes"
      end
      string.freeze
    end

    def validate_arguments(arguments)
      Array(arguments).map do |argument|
        nonempty_value(argument, "native argument")
      end
    end

    def capture_help(flags)
      out, err, status = bounded_capture3(
        bin, *flags, "--help", timeout_sec: CAPTURE_TIMEOUT_SECONDS
      )
      unless status.success?
        raise UnsupportedCapability,
              "#{@name} capability check failed"
      end
      "#{out}\n#{err}"
    rescue Errno::ENOENT, Errno::EACCES, Timeout::Error => e
      raise UnsupportedCapability,
            "#{@name} capability check could not run (#{e.class.name.split('::').last})"
    end

    def flag_advertised?(help, flag)
      help.match?(/(?:\A|[\s,])#{Regexp.escape(flag)}(?:[\s,=\[]|$)/)
    end

    def bounded_capture3(*argv, timeout_sec:)
      stdin, stdout, stderr, waiter = Open3.popen3(*argv, pgroup: true)
      stdin.close
      readers = [ capture_reader(stdout), capture_reader(stderr) ]
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec

      loop do
        unless waiter.alive?
          status = waiter.value
          return [ readers[0].value, readers[1].value, status ] if readers.none?(&:alive?)
        end

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Timeout::Error if remaining <= 0

        sleep [ CAPTURE_POLL_SECONDS, remaining ].min
      end
    rescue Timeout::Error
      terminate_process_group(waiter) if waiter
      readers&.each { |reader| reader.kill if reader.alive? }
      raise
    ensure
      [ stdin, stdout, stderr ].each do |io|
        io.close if io && !io.closed?
      rescue IOError
        nil
      end
    end

    def capture_reader(io)
      Thread.new do
        Thread.current.report_on_exception = false
        io.read
      rescue IOError
        ""
      end
    end

    def terminate_process_group(waiter)
      pid = waiter.pid
      Process.kill("TERM", -pid)
      deadline =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) +
        CAPTURE_TERM_GRACE_SECONDS
      while waiter.alive? &&
            Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep CAPTURE_POLL_SECONDS
      end
      Process.kill("KILL", -pid) if waiter.alive?
      waiter.join(CAPTURE_TERM_GRACE_SECONDS)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end
