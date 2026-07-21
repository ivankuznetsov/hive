require "test_helper"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "hive/agent_skills/canonical_skill"

class ReleaseContractTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../..", __dir__)
  RELEASE_WORKFLOW = File.join(ROOT, ".github/workflows/release.yml")
  LIVE_AGENT_WORKFLOW = File.join(ROOT, ".github/workflows/live-agent-skills.yml")
  RELEASE_SELECTOR = File.join(ROOT, "packaging/live_agent_skills/select_release_proof.rb")
  CANDIDATE_SHA = "a" * 40
  WORKFLOW_SHA = "b" * 40
  ATTESTATION_SHA256 = "c" * 64

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
    selector = read("packaging/live_agent_skills/release_selector.rb")
    workflow = YAML.safe_load_file(RELEASE_WORKFLOW, aliases: true)
    jobs = workflow.fetch("jobs")
    gate = jobs.fetch("proof-gate")

    refute jobs.key?("build")
    refute_includes body, "gem build hive.gemspec"
    assert_equal "web-bundle", gate.fetch("needs")
    assert_equal "proof-gate", jobs.fetch("install-gate").fetch("needs")
    assert_equal [ "proof-gate", "install-gate" ], jobs.fetch("release-finalize").fetch("needs")
    assert_includes body, "commits/${candidate_sha}/check-runs"
    assert_includes body, "packaging/live_agent_skills/select_release_proof.rb"
    assert_includes selector, "OpenClaw live Hive operating skill"
    assert_includes body, "live-agent-skills-proof"
    assert_includes body, "proof_run_attempt"
    assert_includes body, "proof_artifact_digest"
    assert_includes selector, "downloaded proof archive digest does not match"
    assert_includes body, "proof archive contains a symbolic link"
    assert_includes body, "packaging/live_agent_skills/verify.rb"
    assert_includes body, "hive-proven-candidate"
    assert_includes body, "hive-agent-skills-*.tar.gz"
    assert_equal "Verify exact-SHA live agent proof", gate.fetch("name")
  end

  def test_release_builds_and_proves_the_exact_managed_web_archive_before_finalize
    workflow = YAML.safe_load_file(RELEASE_WORKFLOW, aliases: true)
    jobs = workflow.fetch("jobs")
    web_bundle = jobs.fetch("web-bundle")
    proof = jobs.fetch("proof-gate")
    finalize = jobs.fetch("release-finalize")

    package_step = web_bundle.fetch("steps").find do |step|
      step["name"] == "Build exact managed web archive"
    end
    refute_nil package_step
    assert_includes package_step.fetch("run"), "git archive --format=tar.gz"
    assert_includes package_step.fetch("run"), 'echo "sha256=$web_sha" >> "$GITHUB_OUTPUT"'
    assert_equal "${{ steps.archive.outputs.sha256 }}", web_bundle.dig("outputs", "sha256")

    proof_body = proof.fetch("steps").filter_map { |step| step["run"] }.join("\n")
    assert_equal "web-bundle", proof.fetch("needs")
    assert_includes proof_body, "EXPECTED_WEB_SHA"
    assert_includes proof_body, "verify-managed-web-setup.sh"
    assert_includes proof_body, "cp \"$web_archive\" proven/"

    finalize_body = finalize.fetch("steps").filter_map { |step| step["run"] }.join("\n")
    refute_includes finalize_body, "git archive"
    refute finalize.fetch("steps").any? { |step| step["name"] == "Package managed web bundle" }
  end

  def test_release_selector_executes_the_trusted_exact_sha_fixture_contract
    with_release_selector_fixture do |paths|
      out, err, status = run_release_selector("select", *paths.values_at(:checks, :run, :jobs, :artifacts))

      assert status.success?, err
      selection = JSON.parse(out)
      assert_equal CANDIDATE_SHA, selection.fetch("candidate_sha")
      assert_equal WORKFLOW_SHA, selection.fetch("workflow_revision")
      assert_equal 42, selection.fetch("proof_run_id")
      assert_equal 2, selection.fetch("proof_run_attempt")
      assert_equal 77, selection.fetch("proof_artifact_id")
      assert_equal "sha256:#{'d' * 64}", selection.fetch("proof_artifact_digest")
      assert_equal ATTESTATION_SHA256, selection.fetch("attestation_sha256")
    end
  end

  def test_release_selector_rejects_untrusted_or_incomplete_fixtures
    cases = {
      "candidate SHA" => ->(fixture) { fixture.fetch(:checks).fetch("check_runs").first["head_sha"] = "e" * 40 },
      "GitHub Actions app" => ->(fixture) { fixture.fetch(:checks).fetch("check_runs").first["app"]["slug"] = "other" },
      "run attempt" => ->(fixture) { fixture.fetch(:run)["run_attempt"] = 3 },
      "required proof job" => ->(fixture) { fixture.fetch(:jobs).fetch("jobs").shift },
      "nonexpired artifact" => ->(fixture) { fixture.fetch(:artifacts).fetch("artifacts").first["expired"] = true },
      "unique artifact" => lambda { |fixture|
        fixture.fetch(:artifacts).fetch("artifacts") << fixture.fetch(:artifacts).fetch("artifacts").first.dup
      },
      "trusted digest" => ->(fixture) { fixture.fetch(:artifacts).fetch("artifacts").first["digest"] = "sha256:short" }
    }

    cases.each do |label, mutate|
      with_release_selector_fixture(mutate: mutate) do |paths|
        _out, err, status = run_release_selector(
          "select", *paths.values_at(:checks, :run, :jobs, :artifacts)
        )
        refute status.success?, "#{label} fixture should fail"
        refute_empty err
      end
    end
  end

  def test_release_selector_executes_downloaded_archive_digest_verification
    with_tmp_dir do |dir|
      archive = File.join(dir, "proof.zip")
      File.write(archive, "proof archive bytes")
      digest = "sha256:#{Digest::SHA256.file(archive).hexdigest}"

      _out, err, status = run_release_selector("digest", digest, archive, include_identity: false)
      assert status.success?, err

      _out, err, status = run_release_selector(
        "digest", "sha256:#{'0' * 64}", archive, include_identity: false
      )
      refute status.success?
      assert_includes err, "digest does not match"
    end
  end

  def test_signed_checksum_manifest_covers_the_managed_web_bundle
    workflow = read(".github/workflows/release.yml")

    assert_match(
      /sha256sum hive-cli-\*\.gem hive-agent-skills-\*\.tar\.gz hive-web-\*\.tar\.gz > SHA256SUMS/,
      workflow
    )
    assert_includes workflow, "hive-web-${version}.tar.gz"
    assert_includes workflow,
                    '--certificate-identity-regexp "^https://github\\.com/ivankuznetsov/hive/' \
                    '\\.github/workflows/release\\.yml@refs/tags/${REF_NAME}$"'
  end

  private

  def read(path)
    File.read(File.join(ROOT, path))
  end

  def run_release_selector(command, *paths, include_identity: true)
    argv = [ RbConfig.ruby, RELEASE_SELECTOR, command ]
    argv.concat([ CANDIDATE_SHA, "ivankuznetsov/hive" ]) if include_identity
    Open3.capture3(*argv, *paths)
  end

  def with_release_selector_fixture(mutate: nil)
    fixture = release_selector_fixture
    mutate&.call(fixture)
    with_tmp_dir do |dir|
      paths = fixture.to_h do |name, payload|
        path = File.join(dir, "#{name}.json")
        File.write(path, JSON.generate(payload))
        [ name, path ]
      end
      yield paths
    end
  end

  def release_selector_fixture
    external_id = "live-agent-skills:v1:42:2:#{ATTESTATION_SHA256}"
    required_jobs = [
      "OpenClaw live Hive operating skill",
      "Claude live Hive operating skill",
      "Codex live Hive operating skill",
      "Pi live Hive operating skill",
      "Attest exact-SHA live agent proof"
    ]
    {
      checks: {
        "check_runs" => [ {
          "name" => "live-agent-skills", "head_sha" => CANDIDATE_SHA,
          "status" => "completed", "conclusion" => "success",
          "app" => { "slug" => "github-actions" },
          "completed_at" => "2026-07-20T12:00:00Z", "external_id" => external_id,
          "details_url" => "https://github.com/ivankuznetsov/hive/actions/runs/42"
        } ]
      },
      run: {
        "id" => 42, "run_attempt" => 2, "head_sha" => WORKFLOW_SHA,
        "path" => ".github/workflows/live-agent-skills.yml",
        "event" => "workflow_dispatch", "head_branch" => "main",
        "status" => "completed", "conclusion" => "success",
        "head_repository" => { "full_name" => "ivankuznetsov/hive" }
      },
      jobs: {
        "jobs" => required_jobs.map do |name|
          {
            "name" => name, "status" => "completed", "conclusion" => "success",
            "run_id" => 42, "run_attempt" => 2
          }
        end
      },
      artifacts: {
        "artifacts" => [ {
          "id" => 77, "name" => "live-agent-skills-proof-2", "expired" => false,
          "digest" => "sha256:#{'d' * 64}",
          "workflow_run" => { "id" => 42, "head_sha" => WORKFLOW_SHA }
        } ]
      }
    }
  end
end
