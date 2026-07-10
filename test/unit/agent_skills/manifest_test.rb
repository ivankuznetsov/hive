require "test_helper"
require "hive/agent_skills/manifest"
require "hive/commands/init/prompts"
require "hive/stages/review/browser_test"

class AgentSkillsManifestTest < Minitest::Test
  def test_committed_manifest_has_expected_package_and_capability_mappings
    manifest = Hive::AgentSkills::Manifest.load

    assert_equal 1, manifest.schema_version
    assert_equal "compound-engineering@compound-engineering-plugin",
                 manifest.package("compound-engineering").native_for("claude").package
    assert_equal "pr-review-toolkit@claude-plugins-official",
                 manifest.package("pr-review-toolkit").native_for("claude").package
    assert_equal "llm-wiki@aikuznetsov-marketplace",
                 manifest.package("llm-wiki").native_for("claude").package

    assert_equal "/ce-brainstorm", manifest.capability("ce-brainstorm").agent("claude").invocation
    assert_equal "/ce-code-review", manifest.capability("ce-code-review").agent("codex").invocation
    assert_equal "/skill:ce-test-browser", manifest.capability("ce-test-browser").agent("pi").invocation
    assert_equal "/pr-review-toolkit:review-pr",
                 manifest.capability("pr-review-toolkit:review-pr").agent("claude").invocation

    planning = manifest.capability("wiki-plan")
    assert_equal "/plan", planning.agent("claude").invocation
    assert_equal "/llm-wiki:wiki-plan", planning.agent("codex").invocation
    assert_equal "/skill:wiki-plan", planning.agent("pi").invocation
    assert_equal ".claude/commands/plan.md", planning.agent("claude").alias_spec.path
  end

  def test_every_agent_contract_has_an_invocation_and_probe
    manifest = Hive::AgentSkills::Manifest.load

    manifest.capabilities.each do |capability|
      capability.agents.each_value do |agent|
        refute_empty agent.invocation
        refute_empty agent.probe
      end
    end
  end

  def test_builtin_defaults_are_covered_and_browser_test_is_conditional
    manifest = Hive::AgentSkills::Manifest.load

    declarations = Hive::AgentSkills::Manifest.builtin_declarations(
      config: Hive::Config::DEFAULTS,
      reviewer_capabilities: Hive::Commands::Init::Prompts::REVIEWER_CAPABILITIES,
      browser_test_skill: Hive::Stages::Review::BrowserTest::SKILL
    )

    manifest.validate_default_coverage!(declarations)
    refute declarations.any? { |row| row.fetch(:capability) == "ce-test-browser" }

    enabled = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
    enabled["review"]["browser_test"]["enabled"] = true
    browser_declarations = Hive::AgentSkills::Manifest.builtin_declarations(
      config: enabled,
      reviewer_capabilities: Hive::Commands::Init::Prompts::REVIEWER_CAPABILITIES,
      browser_test_skill: Hive::Stages::Review::BrowserTest::SKILL
    )
    assert browser_declarations.any? { |row| row.fetch(:capability) == "ce-test-browser" }
    manifest.validate_default_coverage!(browser_declarations)
  end

  def test_missing_builtin_capability_names_the_declaration
    manifest = Hive::AgentSkills::Manifest.load
    error = assert_raises(Hive::AgentSkills::Manifest::CoverageError) do
      manifest.validate_default_coverage!([
        { surface: "brainstorm", agent: "claude", capability: "future-skill" }
      ])
    end

    assert_match(/brainstorm/, error.message)
    assert_match(/future-skill/, error.message)
  end

  def test_custom_reviewer_is_unmanaged
    manifest = Hive::AgentSkills::Manifest.load

    assert_nil manifest.capability_for(agent: "claude", invocation: "/my-private-review")
  end

  def test_loader_rejects_invalid_manifest_shapes
    base = YAML.safe_load(File.read(Hive::AgentSkills::Manifest.default_path))

    cases = {
      "unknown top-level keys" => ->(doc) { doc["surprise"] = true },
      "unsupported schema versions" => ->(doc) { doc["schema_version"] = 99 },
      "duplicate capability ids" => ->(doc) { doc["capabilities"] << Marshal.load(Marshal.dump(doc["capabilities"].first)) },
      "unsafe sources" => ->(doc) { doc["packages"].first["agents"]["claude"]["source"] = "repo; rm -rf /" },
      "unsafe aliases" => ->(doc) { doc["capabilities"].find { |c| c["id"] == "wiki-plan" }["agents"]["claude"]["alias"]["path"] = "../plan.md" },
      "missing providers" => ->(doc) { doc["packages"].first["agents"]["claude"].delete("provider") },
      "malformed versions" => ->(doc) { doc["packages"].first["version"] = "not a requirement (" }
    }

    cases.each do |label, mutate|
      doc = Marshal.load(Marshal.dump(base))
      mutate.call(doc)
      error = assert_raises(Hive::AgentSkills::Manifest::ValidationError, label) do
        Hive::AgentSkills::Manifest.parse(doc, source: label)
      end
      refute_empty error.message
    end
  end

  def test_loader_wraps_missing_files_and_internal_missing_keys
    missing = File.join(Dir.tmpdir, "hive-agent-skills-#{Process.pid}-missing.yml")
    error = assert_raises(Hive::AgentSkills::Manifest::ValidationError) do
      Hive::AgentSkills::Manifest.load(missing)
    end
    assert_match(/manifest/, error.message)

    document = YAML.safe_load(File.read(Hive::AgentSkills::Manifest.default_path))
    document.define_singleton_method(:fetch) do |key|
      raise KeyError.new("synthetic missing key", key: key) if key == "schema_version"
      super(key)
    end
    error = assert_raises(Hive::AgentSkills::Manifest::ValidationError) do
      Hive::AgentSkills::Manifest.parse(document, source: "synthetic")
    end
    assert_match(/schema_version/, error.message)
  end

  def test_coverage_rejects_capability_agent_not_supported_by_manifest
    manifest = Hive::AgentSkills::Manifest.load

    error = assert_raises(Hive::AgentSkills::Manifest::CoverageError) do
      manifest.validate_default_coverage!([
        { surface: "review", agent: "codex", capability: "pr-review-toolkit:review-pr" }
      ])
    end

    assert_match(/unsupported for codex/, error.message)
  end

  def test_loader_rejects_alias_outside_claude_commands_and_agent_package_mismatch
    base = YAML.safe_load(File.read(Hive::AgentSkills::Manifest.default_path))
    bad_alias = Marshal.load(Marshal.dump(base))
    bad_alias["capabilities"].find { |row| row["id"] == "wiki-plan" }
      .dig("agents", "claude", "alias")["path"] = "commands/plan.md"
    error = assert_raises(Hive::AgentSkills::Manifest::ValidationError) do
      Hive::AgentSkills::Manifest.parse(bad_alias, source: "bad alias root")
    end
    assert_match(/under \.claude\/commands/, error.message)

    mismatch = Marshal.load(Marshal.dump(base))
    contract = Marshal.load(Marshal.dump(
      mismatch["capabilities"].find { |row| row["id"] == "ce-brainstorm" }.dig("agents", "codex")
    ))
    mismatch["capabilities"].find { |row| row["id"] == "pr-review-toolkit:review-pr" }["agents"]["codex"] = contract
    error = assert_raises(Hive::AgentSkills::Manifest::ValidationError) do
      Hive::AgentSkills::Manifest.parse(mismatch, source: "package agent mismatch")
    end
    assert_match(/package pr-review-toolkit does not/, error.message)
  end
end
