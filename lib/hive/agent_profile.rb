require "open3"
require "timeout"
require "hive/implementation_identity"

module Hive
  # Per-CLI invocation contract for a headless agent.
  #
  # Replaces the previous class-level singleton on Hive::Agent that hardcoded
  # claude-only flags. Each profile is a frozen value object that captures
  # everything Hive::Agent#build_cmd needs to spawn one specific CLI: which
  # binary, which flags, how to detect status, what version is required.
  #
  # See docs/notes/headless-agent-cli-matrix.md for the source of truth on
  # each CLI's flag mapping. Profiles ship in lib/hive/agent_profiles/.
  class AgentProfile
    PROMPT_STYLES = %i[positional headless_flag_value stdin].freeze
    WORKSPACE_WRITE_PERMISSION_MODE = "workspace-write".freeze
    READ_ONLY_PERMISSION_MODE = "read-only".freeze
    TOOL_SCOPE_FLAGS_UNSET = Object.new.freeze
    LEGACY_CLAUDE_TOOL_SCOPE_FLAGS = {
      allowed: "--allowedTools",
      disallowed: "--disallowedTools"
    }.freeze
    private_constant :TOOL_SCOPE_FLAGS_UNSET, :LEGACY_CLAUDE_TOOL_SCOPE_FLAGS
    # Status-detection modes. handle_exit branches on these:
    #
    # - :state_file_marker -- read the marker on task.state_file (today's
    #   claude behavior; agent writes the terminal marker itself).
    # - :exit_code_only -- exit 0 = :ok, anything else = :error. No file
    #   inspection. Used by CI-fix loops where the agent's role is "make the
    #   command succeed."
    # - :output_file_exists -- exit 0 AND expected_output file present and
    #   non-empty = :ok. Used by reviewer/triage spawns where the artifact
    #   the agent must produce is the success criterion.
    STATUS_DETECTION_MODES = %i[state_file_marker exit_code_only output_file_exists].freeze

    # Hard cap for `bin --version` invocation in check_version!. Hive picks
    # 10s as a balance: well above any sane CLI's startup time, well below
    # the per-stage timeouts the runner enforces around spawn_and_wait.
    VERSION_CHECK_TIMEOUT_SEC = 10
    CAPTURE_POLL_INTERVAL_SEC = 0.01
    CAPTURE_TERM_GRACE_SEC = 0.2
    CAPTURE_REAP_GRACE_SEC = 0.2
    VERSION_TOKEN_PATTERN =
      /(?<![0-9A-Za-z])v?(\d+\.\d+\.\d+(?:[.-][0-9A-Za-z]+)*)(?![0-9A-Za-z])/
    private_constant :VERSION_TOKEN_PATTERN

    attr_reader :prompt_style
    attr_reader :name, :bin_default, :env_bin_override_key,
                :headless_flag, :permission_skip_flag, :add_dir_flag,
                :budget_flag, :output_format_flags, :version_flag,
                :skill_syntax_format, :headless_supported, :min_version,
                :status_detection_mode, :usage_extractor,
                :workspace_write_flags, :read_only_flags, :cli_capabilities,
                :initial_context_tokens, :default_model_resolver,
                :model_argument_builder, :effort_argument_builder,
                :launcher_identity, :policy_capabilities, :tool_scope_flags

    # Public API — do not break.
    #
    # `Hive::AgentProfiles.register(name, AgentProfile.new(...))` is the
    # documented extension point for projects that ship their own headless
    # agent CLI. The kwargs of `AgentProfile.new` are therefore a public
    # contract: a custom profile registered today MUST keep working when
    # hive ships a new field.
    #
    # Required kwargs (passing one of these is the cost of registering at
    # all — every profile genuinely needs them):
    #   name:                 Symbol identifier (e.g. :claude, :codex, :pi, :grok)
    #   bin_default:          String path to the binary (env override key
    #                         supplied via env_bin_override_key:)
    #   headless_flag:        flag/word that selects headless mode
    #   version_flag:         flag for `<bin> --version`-style probe
    #   skill_syntax_format:  Kernel#format spec used by reviewers to
    #                         render the CE skill invocation
    #
    # Optional kwargs (every one MUST stay optional — adding a 7th
    # required kwarg silently breaks every custom registration):
    #   env_bin_override_key:  default nil (no env var override)
    #   permission_skip_flag:  default nil (no permission gate)
    #   add_dir_flag:          default nil (no --add-dir support)
    #   budget_flag:           default nil (no native budget cap)
    #   output_format_flags:   default [] (none required)
    #   headless_supported:    default true
    #   min_version:           default nil (no version gate)
    #   preflight:             default nil (no extra pre-spawn check)
    #   usage_extractor:       default nil (no token-usage extraction)
    #   workspace_write_flags: default nil (profile cannot guarantee a
    #                          root-confined writable workspace)
    #   read_only_flags:       default nil (profile cannot guarantee a
    #                          read-only workspace)
    #   cli_capabilities:      default {}. Maps a named, opt-in capability to
    #                          the CLI flags that implement it. Capability
    #                          users must call require_cli_capability!, which
    #                          verifies the installed binary advertises every
    #                          flag before returning them.
    #   initial_context_tokens: default 0. Conservative admission reserve for
    #                           provider-owned context sent before the first
    #                           streamed usage event.
    #   tool_scope_flags:      default {} except for a profile named :claude,
    #                          where omission preserves the legacy
    #                          --allowedTools/--disallowedTools mapping. Pass
    #                          an explicit {} to opt out. Maps
    #                          :allowed/:disallowed tool scopes to the
    #                          provider's corresponding flags.
    #   raw_cli_arguments_supported: default false. Explicit opt-in for
    #                          legacy provider-native argv passthrough.
    #   prompt_style:          default :stdin for a profile named :codex,
    #                          otherwise :positional (backward compatible
    #                          with pre-profile-style custom registrations)
    #   status_detection_mode: default :output_file_exists (the most
    #                          common mode across shipped profiles —
    #                          codex and pi both use it; only claude
    #                          deviates with :state_file_marker. A custom
    #                          profile that doesn't override this still
    #                          gets a sane "did the agent write the
    #                          expected output file?" success criterion)
    #
    # Policy: future kwargs MUST have defaults to preserve backward
    # compat for custom profiles. Bumping a default to a different value
    # is a soft break (existing registrations keep working but get
    # different behavior); reserve bumps for genuine bug fixes and call
    # them out in the changelog.
    def initialize(name:, bin_default:, headless_flag:, version_flag:,
                   skill_syntax_format:,
                   env_bin_override_key: nil, permission_skip_flag: nil,
                   add_dir_flag: nil, budget_flag: nil,
                   output_format_flags: [],
                   headless_supported: true, min_version: nil,
                   status_detection_mode: :output_file_exists,
                   preflight: nil,
                   usage_extractor: nil,
                   skill_verifier: nil,
                   workspace_write_flags: nil,
                   read_only_flags: nil,
                   cli_capabilities: {},
                   initial_context_tokens: 0,
                   prompt_style: nil,
                   default_model_resolver: nil,
                   model_argument_builder: nil,
                   effort_argument_builder: nil,
                   launcher_identity: nil,
                   policy_capabilities: [],
                   tool_scope_flags: TOOL_SCOPE_FLAGS_UNSET,
                   raw_cli_arguments_supported: false)
      prompt_style ||= name.to_sym == :codex ? :stdin : :positional
      unless PROMPT_STYLES.include?(prompt_style)
        raise ArgumentError,
              "unknown prompt_style: #{prompt_style.inspect}; valid: #{PROMPT_STYLES.inspect}"
      end

      unless STATUS_DETECTION_MODES.include?(status_detection_mode)
        raise ArgumentError,
              "unknown status_detection_mode: #{status_detection_mode.inspect}; " \
              "valid: #{STATUS_DETECTION_MODES.inspect}"
      end

      unless initial_context_tokens.is_a?(Integer) && initial_context_tokens >= 0
        raise ArgumentError, "initial_context_tokens must be a non-negative Integer"
      end

      @name = name
      @bin_default = bin_default
      @env_bin_override_key = env_bin_override_key
      @headless_flag = headless_flag
      @permission_skip_flag = permission_skip_flag
      @add_dir_flag = add_dir_flag
      @budget_flag = budget_flag
      @output_format_flags = Array(output_format_flags).freeze
      @version_flag = version_flag
      @skill_syntax_format = skill_syntax_format
      @headless_supported = headless_supported
      @min_version = min_version
      @status_detection_mode = status_detection_mode
      @preflight = preflight
      @usage_extractor = usage_extractor || ->(_event) { nil }
      @skill_verifier = skill_verifier
      @workspace_write_flags = Array(workspace_write_flags).freeze
      @read_only_flags = Array(read_only_flags).freeze
      @cli_capabilities = normalize_cli_capabilities(cli_capabilities)
      @initial_context_tokens = initial_context_tokens
      @prompt_style = prompt_style
      @default_model_resolver = default_model_resolver
      @model_argument_builder = model_argument_builder
      @effort_argument_builder = effort_argument_builder
      @launcher_identity = (launcher_identity || "AgentProfile/v1:#{name}").to_s.freeze
      @policy_capabilities = Array(policy_capabilities).map(&:to_sym).uniq.freeze
      @tool_scope_flags = normalize_tool_scope_flags(
        default_tool_scope_flags(name, tool_scope_flags)
      )
      @raw_cli_arguments_supported = raw_cli_arguments_supported == true

      freeze
    end

    # Verifies whether `invocation` (e.g. "/plan",
    # "/ce-plan" or legacy "/compound-engineering:ce-plan") resolves to a real on-disk
    # skill/command for this agent. Profiles supply a callable via the
    # `skill_verifier:` constructor kwarg (typically one of the
    # `Hive::SkillCheck::*` modules). When no verifier is supplied the
    # default is `[:not_applicable, ...]` — the honest answer for an
    # agent with no slash-command-resolution model.
    #
    # `project_root` lets profiles probe project-level overrides
    # (`<repo>/.claude/skills/...` etc.); it may be nil for global
    # checks.
    def verify_skill(invocation, project_root: nil)
      return [ :not_applicable, "no skill verifier configured for this profile" ] unless @skill_verifier

      @skill_verifier.call(invocation, project_root: project_root)
    end

    # Render a configured skill name for this profile. Stage configs
    # historically store full Claude/Codex slash invocations (`/plan`,
    # `/plugin:name`), while reviewer configs store bare names. Profiles
    # with a non-default syntax, such as pi's `/skill:<name>`, need the
    # bare skill name in both cases.
    def format_skill_invocation(skill)
      raw = normalize_legacy_compound_engineering_invocation(skill.to_s)
      if raw.start_with?("/")
        return raw if @skill_syntax_format == "/%{skill}"

        raw = raw.delete_prefix("/")
      end
      raw = raw.split(":", 2).last if @skill_syntax_format != "/%{skill}" && raw.include?(":")

      format(@skill_syntax_format, skill: raw)
    end

    def normalize_legacy_compound_engineering_invocation(raw)
      raw.sub(%r{\A/?compound-engineering:(ce-[A-Za-z0-9-]+)\z}, '\1')
    end

    # Resolved binary path: env override (if env_bin_override_key set and
    # the env var is non-empty) else bin_default.
    def bin
      key = @env_bin_override_key
      return @bin_default unless key

      override = ENV[key]
      override && !override.empty? ? override : @bin_default
    end

    # Permission CLI flags for a spawn, shared by the headless `-p` path
    # (Agent#build_cmd) and the interactive tmux path
    # (ClaudeLauncher#wrapper_command) so the two never diverge. For the
    # claude profile, `bypassPermissions` resolves to the legacy
    # `--dangerously-skip-permissions` flag — identical to a headless
    # spawn — while any other mode uses `--permission-mode <mode>`. A nil
    # mode (or any non-claude profile) falls back to the profile's plain
    # permission_skip_flag, preserving pre-permission_mode behavior.
    def permission_flags(permission_mode = nil)
      if permission_mode == WORKSPACE_WRITE_PERMISSION_MODE
        unless workspace_write_supported?
          raise ArgumentError, "agent profile #{@name.inspect} cannot enforce workspace-write sandboxing"
        end

        return @workspace_write_flags.dup
      end
      if permission_mode == READ_ONLY_PERMISSION_MODE
        unless read_only_supported?
          raise ArgumentError, "agent profile #{@name.inspect} cannot enforce read-only sandboxing"
        end

        return @read_only_flags.dup
      end
      return [] unless @permission_skip_flag
      return [ @permission_skip_flag ] unless @name == :claude && permission_mode
      return [ @permission_skip_flag ] if permission_mode == "bypassPermissions"

      [ "--permission-mode", permission_mode ]
    end

    def workspace_write_supported?
      !@workspace_write_flags.empty?
    end

    def read_only_supported?
      !@read_only_flags.empty?
    end

    def raw_cli_arguments_supported?
      @raw_cli_arguments_supported
    end

    def concrete_default_model(cfg: nil, project_root: nil, home: nil)
      unless @default_model_resolver
        raise Hive::ImplementationIdentity::ResolutionError,
              "agent profile #{@name.inspect} cannot resolve a concrete default model"
      end

      value = @default_model_resolver.call(cfg: cfg, project_root: project_root, home: home)
      Hive::ImplementationIdentity.normalize_model(value, concrete: true)
    rescue Hive::ImplementationIdentity::Error
      raise
    rescue StandardError => e
      raise Hive::ImplementationIdentity::ResolutionError,
            "agent profile #{@name.inspect} default-model resolution failed: #{e.message}"
    end

    def identity_arguments(model:, effort:, pin_model: true)
      normalized_model = Hive::ImplementationIdentity.normalize_model(model, concrete: true)
      requested_effort = Hive::ImplementationIdentity.normalize_effort(effort)
      native_arguments = []
      if pin_model
        unless @model_argument_builder
          raise Hive::ImplementationIdentity::ResolutionError,
                "agent profile #{@name.inspect} cannot pin model #{normalized_model.inspect}"
        end
        native_arguments.concat(@model_argument_builder.call(normalized_model))
      end

      effort_supported = !@effort_argument_builder.nil?
      effective_effort = nil
      if requested_effort && effort_supported
        native_arguments.concat(@effort_argument_builder.call(requested_effort))
        effective_effort = requested_effort
      end

      Hive::ImplementationIdentity::LaunchArguments.new(
        model: normalized_model,
        requested_effort: requested_effort,
        effective_effort: effective_effort,
        effort_supported: effort_supported,
        model_pinned: pin_model,
        native_arguments: Hive::ImplementationIdentity.validate_native_arguments(native_arguments)
      )
    end

    # Return the argv for an explicitly declared CLI capability, but only
    # after the installed binary proves it supports the flags. This keeps a
    # caller from silently weakening a security boundary when an operator
    # overrides the profile binary or pins an older version.
    def require_cli_capability!(capability)
      name = capability.to_sym
      flags = @cli_capabilities[name]
      unless flags
        raise Hive::AgentError,
              "agent profile #{@name.inspect} does not declare CLI capability #{name.inspect}"
      end

      version = check_version!
      key = [ bin, version, name, flags ]
      unless self.class.send(:capability_cache)[key]
        help = capture_help!(flags)
        option_flags = flags.select { |argument| argument.start_with?("-") }
        missing = option_flags.reject { |flag| cli_flag_advertised?(help, flag) }
        unless missing.empty?
          raise Hive::AgentError,
                "#{@name} #{version} does not advertise required #{name} capability " \
                "(missing #{missing.join(', ')})"
        end
        self.class.send(:capability_cache)[key] = true
      end

      flags.dup
    end

    # Project-config override keys that may appear under
    # `agents.<name>.<key>` in <hive-state>/config.yml. Each maps to an
    # AgentProfile constructor kwarg. Unknown keys raise so a typo in
    # config is surfaced loudly instead of silently ignored.
    OVERRIDE_KEYS = {
      "bin" => :bin_default,
      "env_override" => :env_bin_override_key,
      "min_version" => :min_version
    }.freeze

    # Return a new frozen profile with the given override keys applied.
    # `overrides_hash` is a sub-hash of `agents.<name>` from the merged
    # project config; nil/empty hashes return self unchanged.
    #
    # Validates every override key against OVERRIDE_KEYS; an unknown
    # key raises Hive::ConfigError so a typo (`min_versn:`) fails the
    # spawn at lookup time rather than silently keeping the old value.
    def with_overrides(overrides_hash)
      return self if overrides_hash.nil? || overrides_hash.empty?
      unless overrides_hash.is_a?(Hash)
        raise Hive::ConfigError,
              "agents.#{@name} override must be a Hash; got #{overrides_hash.class}"
      end

      kwargs = construction_kwargs
      overrides_hash.each do |key, value|
        kwarg = OVERRIDE_KEYS[key.to_s]
        unless kwarg
          raise Hive::ConfigError,
                "agents.#{@name}.#{key} is not a recognized override key " \
                "(known: #{OVERRIDE_KEYS.keys.inspect})"
        end
        kwargs[kwarg] = value
      end
      self.class.new(**kwargs)
    end

    # Verify the installed binary's version meets min_version.
    #
    # Cached per (bin, min_version) pair so repeated spawns in one process
    # don't re-fork the binary. Returns the parsed version string on success.
    # Raises Hive::AgentError on missing binary, parse failure, or version
    # below min_version. Profiles without min_version skip the comparison.
    def check_version!
      cache_key = [ bin, @min_version ]
      cached = (self.class.send(:version_cache))[cache_key]
      return cached if cached

      unless @headless_supported
        raise Hive::AgentError,
              "agent profile #{@name.inspect} is not headless-supported; " \
              "cannot run from a non-interactive context"
      end

      # Hard timeout protects against wrapper binaries that prompt for
      # credentials or hang on first run. Without this, spawn_agent's
      # preflight could block indefinitely outside the per-stage timeout.
      begin
        out, _err, status = bounded_capture3(
          bin, @version_flag, timeout_sec: VERSION_CHECK_TIMEOUT_SEC
        )
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Hive::AgentError, "#{@name} binary not runnable: #{bin} (#{e.class.name.split('::').last}: #{e.message})"
      rescue Timeout::Error
        raise Hive::AgentError,
              "#{@name} version check timed out after #{VERSION_CHECK_TIMEOUT_SEC}s: #{bin} #{@version_flag}"
      end
      raise Hive::AgentError, "#{@name} binary not runnable: #{bin}" unless status.success?

      versions = out.scan(VERSION_TOKEN_PATTERN).flatten.uniq
      if versions.empty?
        raise Hive::AgentError,
              "could not parse #{@name} #{@version_flag} output: #{out.inspect}"
      end
      if versions.length > 1
        raise Hive::AgentError,
              "ambiguous #{@name} #{@version_flag} output: #{versions.join(', ')}"
      end
      version = versions.fetch(0)

      if @min_version
        cmp = version_tuple(version) <=> version_tuple(@min_version)
        if cmp.nil? || cmp.negative?
          raise Hive::AgentError,
                "#{@name} #{version} below minimum #{@min_version}"
        end
      end

      self.class.send(:version_cache)[cache_key] = version
    end

    # Pre-flight hook for profiles that need extra checks beyond version
    # (e.g., pi requires the user to be logged in to a provider). Profiles
    # supply a Proc at construction via the `preflight:` kwarg; if absent
    # this is a no-op. The Proc receives no arguments and may raise
    # Hive::AgentError to abort the spawn before the binary runs.
    def preflight!
      @preflight&.call
      nil
    end

    def extract_usage_event(event)
      @usage_extractor.call(event)
    rescue StandardError
      nil
    end

    private

    def normalize_cli_capabilities(capabilities)
      unless capabilities.is_a?(Hash)
        raise ArgumentError, "cli_capabilities must be a Hash; got #{capabilities.class}"
      end

      capabilities.each_with_object({}) do |(name, raw_flags), normalized|
        flags = Array(raw_flags).map(&:to_s).reject(&:empty?)
        if flags.empty?
          raise ArgumentError, "CLI capability #{name.inspect} must declare at least one flag"
        end
        normalized[name.to_sym] = flags.freeze
      end.freeze
    end

    def normalize_tool_scope_flags(flags)
      unless flags.is_a?(Hash)
        raise ArgumentError, "tool_scope_flags must be a Hash; got #{flags.class}"
      end

      flags.each_with_object({}) do |(scope, raw_flag), normalized|
        name = scope.to_sym
        unless %i[allowed disallowed].include?(name)
          raise ArgumentError, "unknown tool scope #{scope.inspect}; valid: [:allowed, :disallowed]"
        end
        flag = raw_flag.to_s
        raise ArgumentError, "tool scope #{scope.inspect} must declare a flag" if flag.empty?

        normalized[name] = flag.freeze
      end.freeze
    end

    def default_tool_scope_flags(name, flags)
      return flags unless flags.equal?(TOOL_SCOPE_FLAGS_UNSET)
      return LEGACY_CLAUDE_TOOL_SCOPE_FLAGS if name.to_sym == :claude

      {}
    end

    def capture_help!(capability_flags)
      out, err, status = bounded_capture3(
        bin, *capability_flags, "--help", timeout_sec: VERSION_CHECK_TIMEOUT_SEC
      )
      unless status.success?
        raise Hive::AgentError,
              "#{@name} capability check failed: #{([ bin, *capability_flags, '--help' ]).join(' ')}"
      end

      "#{out}\n#{err}"
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Hive::AgentError,
            "#{@name} capability check could not run #{bin} (#{e.class.name.split('::').last}: #{e.message})"
    rescue Timeout::Error
      raise Hive::AgentError,
            "#{@name} capability check timed out after #{VERSION_CHECK_TIMEOUT_SEC}s: #{bin}"
    end

    # Capture one short-lived CLI probe under a real process-group deadline.
    # `Timeout.timeout { Open3.capture3(...) }` interrupts only the Ruby caller;
    # Open3's pipe readers can still wait forever for a hung child or descendant.
    # Owning the pipes and waiter gives timeout a bounded TERM/KILL escalation
    # and reap window before control returns to version/capability callers.
    def bounded_capture3(*argv, timeout_sec:)
      stdin, stdout, stderr, waiter = Open3.popen3(*argv, pgroup: true)
      stdin.close
      readers = [ capture_reader(stdout), capture_reader(stderr) ]
      deadline = monotonic_now + timeout_sec

      loop do
        unless waiter.alive?
          status = waiter.value
          return [ readers[0].value, readers[1].value, status ] if readers.none?(&:alive?)
        end

        remaining = deadline - monotonic_now
        raise Timeout::Error if remaining <= 0

        sleep [ CAPTURE_POLL_INTERVAL_SEC, remaining ].min
      end
    rescue Timeout::Error
      terminate_capture_process_group(waiter) if waiter
      stop_capture_readers(readers, stdout, stderr)
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

    def terminate_capture_process_group(waiter)
      pid = waiter.pid
      signal_capture_process_group("TERM", pid)
      deadline = monotonic_now + CAPTURE_TERM_GRACE_SEC
      while capture_process_group_alive?(pid) && monotonic_now < deadline
        sleep CAPTURE_POLL_INTERVAL_SEC
      end
      signal_capture_process_group("KILL", pid) if capture_process_group_alive?(pid)
      waiter.join(CAPTURE_REAP_GRACE_SEC)
    end

    def stop_capture_readers(readers, *streams)
      Array(readers).each { |reader| reader.join(CAPTURE_REAP_GRACE_SEC) }
      streams.each do |stream|
        stream.close if stream && !stream.closed?
      rescue IOError
        nil
      end
      Array(readers).each { |reader| reader.kill if reader.alive? }
    end

    def signal_capture_process_group(signal, pid)
      Process.kill(signal, -Integer(pid))
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def capture_process_group_alive?(pid)
      Process.kill(0, -Integer(pid))
      true
    rescue Errno::ESRCH, Errno::ECHILD
      false
    rescue Errno::EPERM
      true
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def cli_flag_advertised?(help, flag)
      help.match?(/(?<![A-Za-z0-9_-])#{Regexp.escape(flag)}(?![A-Za-z0-9_-])/)
    end

    def version_tuple(version_string)
      version_string.split(".").map(&:to_i)
    end

    # Snapshot of every kwarg the constructor takes, so with_overrides
    # can build a sibling profile that differs only in the overridden
    # fields. Mirrored 1:1 against `initialize`'s kwarg list — adding
    # a new field requires updating both spots.
    def construction_kwargs
      {
        name: @name,
        bin_default: @bin_default,
        env_bin_override_key: @env_bin_override_key,
        headless_flag: @headless_flag,
        permission_skip_flag: @permission_skip_flag,
        add_dir_flag: @add_dir_flag,
        budget_flag: @budget_flag,
        output_format_flags: @output_format_flags.dup,
        version_flag: @version_flag,
        skill_syntax_format: @skill_syntax_format,
        headless_supported: @headless_supported,
        min_version: @min_version,
        status_detection_mode: @status_detection_mode,
        preflight: @preflight,
        usage_extractor: @usage_extractor,
        skill_verifier: @skill_verifier,
        workspace_write_flags: @workspace_write_flags.dup,
        read_only_flags: @read_only_flags.dup,
        cli_capabilities: @cli_capabilities.transform_values(&:dup),
        initial_context_tokens: @initial_context_tokens,
        prompt_style: @prompt_style,
        default_model_resolver: @default_model_resolver,
        model_argument_builder: @model_argument_builder,
        effort_argument_builder: @effort_argument_builder,
        launcher_identity: @launcher_identity,
        policy_capabilities: @policy_capabilities.dup,
        tool_scope_flags: @tool_scope_flags.dup,
        raw_cli_arguments_supported: @raw_cli_arguments_supported
      }
    end

    class << self
      def reset_version_cache!
        @version_cache = nil
        @capability_cache = nil
      end

      private

      def version_cache
        @version_cache ||= {}
      end

      def capability_cache
        @capability_cache ||= {}
      end
    end
  end
end
