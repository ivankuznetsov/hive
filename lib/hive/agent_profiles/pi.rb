require "hive/agent_profile"

module Hive
  module AgentProfiles
    # Pi (mariozechner/pi-coding-agent) profile. Headless via -p / --print.
    #
    # Two ADR-008 boundary gaps documented in U11's matrix:
    # - No --add-dir-equivalent flag; filesystem isolation is the OS user's
    #   bound only. ADR-018 amends ADR-008 to cover this trade-off.
    # - No permission-skip flag; tools (read, bash, edit, write) are enabled
    #   by default. Use --tools <allowlist> for tool-level restriction in
    #   read-only roles (e.g., reviewer).
    #
    # Pre-registered as profile-able but NOT in hive's default reviewer set
    # — users opt in per project. Pi requires an interactive provider login
    # before it can be invoked headless; PiProfile#preflight! enforces this.
    #
    # Source of truth: docs/notes/headless-agent-cli-matrix.md (pi column).
    # Verify pi is logged in to a provider. ~/.pi/agent/auth.json being
    # empty {} means the user hasn't run `pi` interactively to log in yet.
    PI_PREFLIGHT = -> {
      auth_path = File.expand_path("~/.pi/agent/auth.json")
      unless File.exist?(auth_path)
        raise Hive::AgentError,
              "pi profile preflight failed: #{auth_path} not found. " \
              "Run `pi` interactively and log in to a provider before using pi as a hive agent CLI."
      end

      content = File.read(auth_path).strip
      if content.empty? || content == "{}"
        raise Hive::AgentError,
              "pi profile preflight failed: no provider configured. " \
              "Run `pi` interactively and log in to a provider before using pi as a hive agent CLI."
      end

      nil
    }

    PI = AgentProfile.new(
      name: :pi,
      bin_default: "pi",
      env_bin_override_key: "HIVE_PI_BIN",
      headless_flag: "-p",
      permission_skip_flag: nil, # pi has no permission gate
      add_dir_flag: nil,         # pi has no --add-dir
      budget_flag: nil,
      output_format_flags: [ "--mode", "json", "--no-session" ],
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      headless_supported: true,
      min_version: "0.70.2",
      status_detection_mode: :output_file_exists,
      preflight: PI_PREFLIGHT
    )

    register(:pi, PI)
  end
end
