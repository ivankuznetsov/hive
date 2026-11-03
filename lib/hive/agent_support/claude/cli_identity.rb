require "hive/agent_support/claude"

module Hive::AgentSupport::Claude::CliIdentity
  module_function

  def dynamic_launcher?(_target) = false
  def native_version_first? = false

  def native_version(target, version_pattern:)
    match = target.match(%r{/\.local/share/claude/versions/([^/]+)\z})
    [ match[1], "claude_native_install", nil ] if match && version_pattern.match?(match[1])
  end
end
