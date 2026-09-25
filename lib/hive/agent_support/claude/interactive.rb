module Hive::AgentSupport::Claude::Interactive
  READY_WAIT_TIMEOUT_SEC = 120
  READY_POLL_INTERVAL_SEC = 0.25
  TRUST_OPTION = "Yes, I trust this folder".freeze
  # Claude Code has shipped two folder-trust layouts: the older "Quick safety
  # check" with "Yes" as option 1, and a newer "Is this a project you created
  # or one you trust?" whose caret starts on "No, exit". Either context line
  # plus the trust option identifies the prompt.
  TRUST_CONTEXT_MARKERS = [ "Quick safety check", "one you trust", "Enter to confirm" ].freeze
  PERMISSION_MARKER = "Do you want to".freeze
  READY_BANNER = "Claude Code".freeze
  READY_FOOTER = "for agents".freeze
  FOOTER_HINT = "bypass permissions".freeze
  # Claude Code keeps the input caret and footer painted while a turn runs;
  # only the footer's interrupt hint distinguishes a working pane from idle.
  BUSY_MARKER = "esc to interrupt".freeze
  READY_LINE = /\A❯(?:[\p{Zs}\s]|\z)|(?:[\p{Zs}\s])❯\z/u.freeze
  MENU_LINE = /\A\s*❯\s*\d+\./.freeze
  CHROME_LINE = /\A[\p{Zs}\s?+\-─━│┄┈┉┅┇┊┋┆┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬╭╮╰╯╴╵╶╷╸╹╺╻╼╽╾╿]+\z/u.freeze
  PROMPT_LINES = 12
  TRUST_PROMPT_LINES = 16
  # A repainted session banner means any trust dialog above it is scrollback.
  VERSION_BANNER_LINE = /\AClaude Code v\d/.freeze

  PLANNER_TOOLS = "Read,Write,Edit,LS".freeze
  IMPLEMENTER_TOOLS = "Read,Write,Edit,Bash,LS,Glob,Grep".freeze

  def ensure_claude_profile!(profile)
    return if profile.name == :claude

    raise Hive::AgentError, "ClaudeLauncher only supports the claude profile; got #{profile.name.inspect}"
  end

  def wrapper_command(cwd:, add_dirs:, profile:, permission_mode:,
                      allowed_tools: PLANNER_TOOLS, disallowed_tools: nil,
                      cli_flags: [], mcp_config_path: nil,
                      strict_mcp_config: false, runtime_policy: nil)
    if runtime_policy
      add_dirs = runtime_policy.directories
      permission_mode = runtime_policy.permission_mode
      allowed_tools = runtime_policy.allowed_tools
      disallowed_tools = runtime_policy.disallowed_tools
    end
    command = [
      "bash", File.expand_path("../../scripts/interactive_claude_wrapper.sh", __dir__),
      "--cwd", cwd
    ]
    Array(add_dirs).each { |dir| command.concat([ "--add-dir", dir ]) }
    command.concat(profile.permission_flags(permission_mode))
    command.concat(Array(cli_flags))
    command.concat(runtime_policy ? runtime_policy.cli_flags : mcp_cli_flags(mcp_config_path, strict_mcp_config))
    allowed = Hive::PermissionScope.tool_csv(allowed_tools)
    disallowed = Hive::PermissionScope.tool_csv(disallowed_tools)
    command.concat([ "--allowedTools", allowed ]) if allowed
    command.concat([ "--disallowedTools", disallowed ]) if disallowed
    command.concat([ "--bin", profile.bin ])
  end

  def isolated_managed_command(command, runtime_policy, task)
    environment = runtime_policy.environment.merge(
      Hive::AgentProfiles.lookup(:claude).subscription_environment(unset_value: "")
    ).merge("HIVE_SCREENOTE_BASE_URL" => "", "HIVE_TASK_STAGE_DIR" => task.folder)
    [ "/usr/bin/env", "-i", *environment.sort.map { |key, value| "#{key}=#{value}" }, *command ]
  end

  def mcp_cli_flags(path, strict)
    return [] if path.to_s.strip.empty?

    flags = [ "--mcp-config", path ]
    flags << "--strict-mcp-config" if strict
    flags
  end

  def claude_trust_prompt?(pane)
    trust_prompt_text?(trust_prompt_region(pane))
  end

  # Keys that move the folder-trust prompt toward accepting trust. Enter only
  # confirms when the caret is on the trust option; otherwise move down and let
  # the next poll re-read the menu, so a "No, exit" default is never confirmed.
  def claude_trust_prompt_keys(pane)
    caret = trust_prompt_region(pane).each_line.map(&:strip).find { |line| line.start_with?("❯") }
    caret&.include?(TRUST_OPTION) ? [ "Enter" ] : [ "Down" ]
  end

  # The newer trust dialog separates its options and footer with blank lines,
  # so read a window of recent non-empty lines instead of only the text after
  # the last blank line.
  def trust_prompt_region(pane)
    lines = pane.each_line.map(&:strip)
    banner = lines.rindex { |line| line.match?(VERSION_BANNER_LINE) }
    lines[(banner ? banner + 1 : 0)..].reject(&:empty?).last(TRUST_PROMPT_LINES).join("\n")
  end

  def trust_prompt_text?(text)
    text.include?(TRUST_OPTION) && TRUST_CONTEXT_MARKERS.any? { |marker| text.include?(marker) }
  end

  def claude_ready_prompt?(pane)
    text = current_prompt_text(pane)
    lines = text.each_line.map(&:strip).reject(&:empty?)
    return false if trust_prompt_text?(text)
    return false if text.include?(PERMISSION_MARKER)
    return false if text.include?(BUSY_MARKER)
    return false unless pane.include?(READY_BANNER) || text.include?(READY_FOOTER)

    caret = lines.rindex { |line| line.match?(READY_LINE) && !line.match?(MENU_LINE) }
    return false unless caret

    lines[(caret + 1)..].all? { |line| claude_prompt_chrome_line?(line) }
  end

  def claude_prompt_chrome_line?(line)
    line.include?(READY_FOOTER) ||
      (line.start_with?("⏵⏵") && line.include?(FOOTER_HINT)) ||
      line.match?(CHROME_LINE)
  end

  def current_prompt_text(pane)
    lines = pane.each_line.map(&:strip)
    blank = lines.rindex("")
    banner = lines.rindex { |line| line.include?(READY_BANNER) }
    lines[[ banner, blank && blank + 1, 0 ].compact.max..]
      .reject(&:empty?).last(PROMPT_LINES).join("\n")
  end
end
