require "test_helper"
require "json"
require "hive/agent_skills/canonical_skill"

class ReleaseContractTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  RELEASE_WORKFLOW = File.join(ROOT, ".github/workflows/release.yml")

  def test_release_metadata_matches_runtime_version
    version = Regexp.escape(Hive::VERSION)

    assert_match(/^    hive-cli \(#{version}\)$/, read("Gemfile.lock"))
    assert_match(/^    hive-cli \(#{version}\)$/, read("web/Gemfile.lock"))
    assert_equal 1, read("CHANGELOG.md").scan(/^## #{version}$/).size
    assert_equal 1, read("README.md").scan(%r{/v#{version}/install\.sh}).size
    assert_equal 2, read("install.md").scan(%r{/v#{version}/install\.sh}).size
  end

  def test_discord_announcement_uses_supported_update_command
    workflow = YAML.safe_load_file(RELEASE_WORKFLOW, aliases: true)
    step = workflow.fetch("jobs").fetch("release-finalize").fetch("steps").find do |candidate|
      candidate["name"] == "Announce release on Discord"
    end

    refute_nil step
    assert_equal "${{ env.DISCORD_RELEASE_WEBHOOK != '' }}", step.fetch("if")
    assert_equal true, step.fetch("continue-on-error")
    assert_includes step.fetch("run"), "\\`hive update\\`"
    refute_includes step.fetch("run"), "gem install hive-cli"
  end

  def test_agent_skill_release_metadata_is_derived_from_authoritative_inputs
    canonical = Hive::AgentSkills::CanonicalSkill.new
    skill_text = File.read(File.join(ROOT, "openclaw/skills/hive/SKILL.md"))
    frontmatter = skill_text.match(/\A---\n(?<yaml>.*?)\n---\n/m)[:yaml]
    openclaw = YAML.safe_load(frontmatter, aliases: false)
    projection = JSON.parse(File.read(File.join(ROOT, "openclaw/skills/hive/.hive-skill.json")))
    setup = File.read(File.join(ROOT, "openclaw/skills/hive/references/setup-and-platforms.md"))
    publish_docs = read("openclaw/README.md")

    assert_equal canonical.version, openclaw.fetch("version")
    assert_equal canonical.version, projection.fetch("skill_version")
    assert_equal canonical.canonical_digest, projection.fetch("canonical_digest")
    assert_includes setup, "/v#{Hive::VERSION}/install.sh"
    refute_match(%r{/v(?!#{Regexp.escape(Hive::VERSION)}/)[0-9]+\.[0-9]+\.[0-9]+/install\.sh}, setup)
    assert_includes publish_docs, "skills/hive/skill.json"
    refute_match(/--version\s+\d+\.\d+\.\d+/, publish_docs)
  end

  private

  def read(path)
    File.read(File.join(ROOT, path))
  end
end
