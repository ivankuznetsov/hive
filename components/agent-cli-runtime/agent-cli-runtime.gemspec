require_relative "lib/agent_cli_runtime/version"

Gem::Specification.new do |spec|
  spec.name = "agent-cli-runtime"
  spec.version = AgentCliRuntime::VERSION
  spec.authors = [ "Ivan Kuznetsov" ]
  spec.email = [ "ivan@ikuznetsov.com" ]
  spec.summary =
    "One Ruby API for Claude Code, Codex CLI, Pi, Grok CLI, and OpenCode"
  spec.description = <<~DESC
    Agent CLI Runtime gives Ruby applications one stable integration layer for
    local coding-agent CLIs. It builds provider-specific commands from a shared
    request model, checks local versions and named capabilities, and normalizes
    usage and results afterward. Centralized profiles, environment rules, and
    parsers make agent providers easier to add, switch, and upgrade.
  DESC
  spec.homepage = "https://github.com/ivankuznetsov/agent-cli-runtime"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" =>
      "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/ivankuznetsov/hive/issues",
    "documentation_uri" =>
      "#{spec.homepage}/blob/main/README.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "lib/**/*.rb",
      "exe/agent-runtime",
      "README.md",
      "CHANGELOG.md",
      "LICENSE.txt",
      "agent-cli-runtime.gemspec"
    ]
  end
  spec.bindir = "exe"
  spec.executables = [ "agent-runtime" ]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "json", ">= 2.7", "< 3.0"
  spec.add_dependency "open3", "~> 0.2"
  spec.add_dependency "timeout", ">= 0.4", "< 1.0"
end
