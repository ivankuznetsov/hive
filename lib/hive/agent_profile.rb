require "open3"
require "timeout"

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

    attr_reader :name, :bin_default, :env_bin_override_key,
                :headless_flag, :permission_skip_flag, :add_dir_flag,
                :budget_flag, :output_format_flags, :version_flag,
                :skill_syntax_format, :headless_supported, :min_version,
                :status_detection_mode

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
    #   name:                 Symbol identifier (e.g. :claude, :codex, :pi)
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
                   preflight: nil)
      unless STATUS_DETECTION_MODES.include?(status_detection_mode)
        raise ArgumentError,
              "unknown status_detection_mode: #{status_detection_mode.inspect}; " \
              "valid: #{STATUS_DETECTION_MODES.inspect}"
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

      freeze
    end

    # Resolved binary path: env override (if env_bin_override_key set and
    # the env var is non-empty) else bin_default.
    def bin
      key = @env_bin_override_key
      return @bin_default unless key

      override = ENV[key]
      override && !override.empty? ? override : @bin_default
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
        out, _err, status = Timeout.timeout(VERSION_CHECK_TIMEOUT_SEC) do
          Open3.capture3(bin, @version_flag)
        end
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Hive::AgentError, "#{@name} binary not runnable: #{bin} (#{e.class.name.split('::').last}: #{e.message})"
      rescue Timeout::Error
        raise Hive::AgentError,
              "#{@name} version check timed out after #{VERSION_CHECK_TIMEOUT_SEC}s: #{bin} #{@version_flag}"
      end
      raise Hive::AgentError, "#{@name} binary not runnable: #{bin}" unless status.success?

      version = out[/\d+\.\d+\.\d+/]
      raise Hive::AgentError, "could not parse #{@name} #{@version_flag} output: #{out.inspect}" unless version

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

    private

    def version_tuple(version_string)
      version_string.split(".").map(&:to_i)
    end

    class << self
      def reset_version_cache!
        @version_cache = nil
      end

      private

      def version_cache
        @version_cache ||= {}
      end
    end
  end
end
