# Claude launch facet: the tool scopes, always-denied tools, MCP flags, and
# profile guard every Claude launch shares. `AgentSupport.supports?(profile,
# :Launch)` is how callers ask "is this the Claude profile?".
module Hive::AgentSupport::Claude::Launch
  PLANNER_TOOLS = "Read,Write,Edit,LS".freeze
  IMPLEMENTER_TOOLS = "Read,Write,Edit,Bash,LS,Glob,Grep".freeze
  # A detached launch has no one to answer a question menu, so it would hang
  # the stage until its timeout. Every launch denies it, whatever the
  # permission scope.
  DENIED_TOOLS = %w[AskUserQuestion].freeze

  def ensure_claude_profile!(profile)
    return if profile.name == :claude

    raise Hive::AgentError, "ClaudeLauncher only supports the claude profile; got #{profile.name.inspect}"
  end

  def mcp_cli_flags(path, strict)
    return [] if path.to_s.strip.empty?

    flags = [ "--mcp-config", path ]
    flags << "--strict-mcp-config" if strict
    flags
  end
end
