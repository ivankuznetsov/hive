require "test_helper"
require "json"
require "hive/agent_skills/canonical_skill"

class ReleaseContractTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  RELEASE_WORKFLOW = File.join(ROOT, ".github/workflows/release.yml")
  LIVE_AGENT_WORKFLOW = File.join(ROOT, ".github/workflows/live-agent-skills.yml")

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

  def test_live_agent_proof_is_protected_exact_sha_and_four_surface
    body = File.read(LIVE_AGENT_WORKFLOW)
    workflow = YAML.safe_load_file(LIVE_AGENT_WORKFLOW, aliases: true)
    jobs = workflow.fetch("jobs")
    matrix = jobs.fetch("live-agent").dig("strategy", "matrix", "include")

    assert_includes body, "workflow_dispatch:"
    assert_includes body, "candidate_sha:"
    assert_includes body, '[[ "$GITHUB_REF" == "refs/heads/main" ]]'
    assert_includes body, "git merge-base --is-ancestor"
    assert_includes body, "branches/main"
    assert_equal %w[claude codex openclaw pi], matrix.map { |row| row.fetch("platform") }.sort
    assert_equal "live-agent-skills-${{ matrix.platform }}", jobs.fetch("live-agent").fetch("environment")
    assert_equal false, jobs.fetch("live-agent").dig("strategy", "fail-fast")
    assert_equal [ "validate", "build", "live-agent" ], jobs.fetch("attest").fetch("needs")
    assert_includes body, "retention-days: 7"
    assert_includes body, 'name: "live-agent-skills"'
    assert_includes body, "checks: write"
    assert_includes body, "attestation_sha256"
    assert_includes body, "HIVE_RELEASE_GATE: \"1\""

    live_step = jobs.fetch("live-agent").fetch("steps").find do |step|
      step["name"] == "Run authenticated structural proof"
    end
    refute_nil live_step
    assert_includes live_step.dig("env", "CODEX_API_KEY"), "matrix.platform == 'codex'"
    assert_includes live_step.dig("env", "ANTHROPIC_API_KEY"), "matrix.platform == 'claude'"
    assert_includes live_step.dig("env", "ANTHROPIC_API_KEY"), "matrix.platform == 'pi'"
    assert_includes live_step.dig("env", "OPENAI_API_KEY"), "matrix.platform == 'openclaw'"
    install_step = jobs.fetch("live-agent").fetch("steps").find do |step|
      step["name"] == "Install the native agent CLI in the ephemeral runner"
    end
    refute install_step.fetch("env").key?("CODEX_API_KEY")
  end

  def test_tag_release_consumes_attested_artifacts_without_rebuilding
    body = File.read(RELEASE_WORKFLOW)
    workflow = YAML.safe_load_file(RELEASE_WORKFLOW, aliases: true)
    jobs = workflow.fetch("jobs")
    gate = jobs.fetch("proof-gate")

    refute jobs.key?("build")
    refute_includes body, "gem build hive.gemspec"
    assert_equal "proof-gate", jobs.fetch("install-gate").fetch("needs")
    assert_equal [ "proof-gate", "install-gate" ], jobs.fetch("release-finalize").fetch("needs")
    assert_includes body, "commits/${candidate_sha}/check-runs"
    assert_includes body, '.app.slug == "github-actions"'
    assert_includes body, '.path == $path'
    assert_includes body, '.event == "workflow_dispatch"'
    assert_includes body, "OpenClaw live Hive operating skill"
    assert_includes body, "live-agent-skills-proof"
    assert_includes body, "proof_run_attempt"
    assert_includes body, "proof_artifact_digest"
    assert_includes body, "downloaded proof archive digest does not match"
    assert_includes body, "proof archive contains a symbolic link"
    assert_includes body, "packaging/live_agent_skills/verify.rb"
    assert_includes body, "hive-proven-candidate"
    assert_includes body, "hive-agent-skills-*.tar.gz"
    assert_equal "Verify exact-SHA live agent proof", gate.fetch("name")
  end

  private

  def read(path)
    File.read(File.join(ROOT, path))
  end
end
