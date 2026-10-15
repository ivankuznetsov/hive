require "test_helper"

# Hive::Agent is the MCP choke point, but some launchers compile and spawn
# an agent themselves. Every site that builds an agent command must render
# Hive-owned MCP (reference Hive::Mcp or an mcp_launch), or be listed here
# with the reason it is exempt (plan 2026-10-15-001, U4).
class McpLaunchSiteContractTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  SPAWN_SITE = /\bAgentRuntime\.compile\(|\bHive::Agent\.new\(|\[\s*profile\.bin\b|^\s*profile\.bin,\s*$/
  GUARD = /\bHive::Mcp\b|\bmcp_launch\b/
  EXEMPT = {
    "lib/hive/mcp.rb" => "owns the rendering",
    "lib/hive/tui/bubble_model.rb" => "interactive steer session the operator drives in their own terminal"
  }.freeze

  def self.unguarded(sources)
    sources.filter_map do |path, source|
      code = source.lines.reject { |line| line.lstrip.start_with?("#") }.join
      path if code.match?(SPAWN_SITE) && !code.match?(GUARD) && !EXEMPT.key?(path)
    end
  end

  def lib_sources
    Dir[File.join(ROOT, "lib", "**", "*.rb")].to_h do |path|
      [ path.delete_prefix("#{ROOT}/"), File.read(path) ]
    end
  end

  def test_every_agent_spawn_site_renders_hive_mcp
    sources = lib_sources
    assert_empty self.class.unguarded(sources)
    EXEMPT.each_key { |path| assert sources.key?(path), "stale exemption #{path}" }
    %w[
      lib/hive/agent.rb lib/hive/diagnosis_agent.rb lib/hive/agent_support/codex/reviewer.rb
      lib/hive/agent_support/opencode/execution.rb lib/hive/patrol/reviewer.rb
    ].each { |path| assert_match SPAWN_SITE, sources.fetch(path), "#{path} is no longer a spawn site" }
  end

  def test_an_injected_unguarded_site_fails
    sources = {
      "lib/hive/new_launcher.rb" => "invocation = Hive::AgentRuntime.compile(request)\n",
      "lib/hive/guarded.rb" => "Hive::Mcp.with_launch(**opts) { |launch| Hive::Agent.new(mcp_launch: launch) }\n",
      "lib/hive/commented.rb" => "# Hive::Agent.new(task:) is documented here only\n",
      "lib/hive/raw.rb" => "argv = [ profile.bin, \"exec\" ]\n"
    }

    assert_equal %w[lib/hive/new_launcher.rb lib/hive/raw.rb], self.class.unguarded(sources)
  end
end
