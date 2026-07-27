require "test_helper"
require "json"
require "pathname"
require "yaml"
require "hive/agent_skills/canonical_skill"

class OpenClawSkillsTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../openclaw/skills").expand_path
  README = Pathname.new(__dir__).join("../../openclaw/README.md").expand_path
  HOMEPAGE = "https://github.com/ivankuznetsov/hive"
  CLAWHUB_SLUG = "hive-cli"
  CLAWHUB_REF = "@ivankuznetsov/#{CLAWHUB_SLUG}"
  CLAWHUB_LISTING = "https://clawhub.ai/ivankuznetsov/skills/#{CLAWHUB_SLUG}"

  def test_only_umbrella_skill_is_published_through_clawhub
    actual = ROOT.glob("*/SKILL.md").map { |path| path.dirname.basename.to_s }.sort

    assert_equal [ "hive" ], actual
  end

  def test_rendered_frontmatter_supports_setup_before_hive_is_installed
    metadata, body = read_skill("hive")
    canonical = Hive::AgentSkills::CanonicalSkill.new
    openclaw_metadata = metadata.fetch("metadata").fetch("openclaw")

    assert_equal "hive", metadata.fetch("name")
    assert_equal canonical.description, metadata.fetch("description")
    assert_equal canonical.version, metadata.fetch("version")
    assert_equal true, metadata.fetch("user-invocable")
    assert_equal HOMEPAGE, openclaw_metadata.fetch("homepage")
    assert_equal true, openclaw_metadata.fetch("always")
    refute openclaw_metadata.dig("requires", "bins")

    installer = openclaw_metadata.fetch("install").find { |entry| entry.fetch("id") == "homebrew" }
    assert_equal "brew", installer.fetch("kind")
    assert_equal "ivankuznetsov/hive/hive", installer.fetch("formula")
    assert_equal [ "hive" ], installer.fetch("bins")
    assert_includes body, "invocation: /hive"
    assert_includes body, "canonical-digest: #{canonical.canonical_digest}"
  end

  def test_projection_uses_native_status_watch_and_progressive_references
    text = projection_text

    assert_includes text, "hive status --operational --json"
    assert_includes text, "hive watch PROJECT:SLUG"
    assert_includes text, "--json-lines"
    assert_includes text, "hive act ACTION_ID"
    assert_includes text, "hive setup-agents --yes --json"
    assert_includes text, "OpenClaw: `/hive`"
    assert_includes text, "Pi: `/skill:hive`"
    assert_includes text, "/v#{Hive::VERSION}/install.sh"

    %w[HIVE_WATCH_INTERVAL HIVE_WATCH_TIMEOUT mapfile].each do |legacy|
      refute_includes text, legacy
    end
    refute_match(/pgrep\s+-af|kill\s+-0|while\s+:/, text)
  end

  def test_projection_routes_natural_language_workflow_creation_inside_hive
    root = ROOT.join("hive")
    creator_references = %w[
      workflow-creator.md
      workflow-creator-example.md
      workflow-schema.md
      workflow-stage-design.md
      workflow-checkpoints.md
      workflow-permissions.md
      workflow-testing.md
      workflow-common-mistakes.md
    ]

    creator_references.each do |name|
      assert root.join("references", name).file?, name
    end

    text = projection_text
    assert_includes text, "hive-workflow-creator"
    assert_includes text, "hive workflow validate ID --json"
    assert_includes text, "No task by default"
    assert_includes text, "Never publish externally"
  end

  def test_projection_keeps_recovery_and_release_authority_guarded
    text = projection_text
    normalized_text = text.gsub(/\s+/, " ")

    %w[markers\ clear approve\ --force daemon\ stop].each do |escaped|
      assert_includes text, escaped.tr("\\", "")
    end
    assert_includes text, "hive act workflow.retry"
    assert_includes text, "hive migrate PROJECT_PATH"
    assert_includes text, "RecoveryCoordinator"
    assert_includes normalized_text, "not a retry recipe"
    assert_includes text, "obtain explicit confirmation"
    assert_includes text, "separate explicit release request"
    assert_includes text, "Do not create or push a tag"
    assert_includes text, "Do not print, copy wholesale, or persist agent credentials"
  end

  def test_projection_preserves_consent_safe_setup_from_canonical_source
    text = projection_text

    assert_includes text, "hive setup --no-init --yes --json"
    assert_includes text, "hive setup --no-init --no-service --yes --json"
    assert_includes text, "service.service_installed"
    assert_includes text, "service.service_enabled"
    assert_includes text, "service.service_running"
    assert_includes text, "service.ready"
    assert_includes text, "service.readiness"
    assert_includes text, "hive web status --json"
    assert_match(/Prefer this native managed-service path.*Choose Hivebox/m, text)
    assert_includes text, "their own real terminal"
    assert_includes text, "openclaw skills install #{CLAWHUB_REF}"
    assert_includes text, "Never patch an installed Hive runtime"
    refute_match(/(?:yay|paru)[^\n]*--noconfirm/, text)
  end

  def test_projection_manifest_records_exact_files_and_shared_identity
    root = ROOT.join("hive")
    manifest = JSON.parse(root.join(".hive-skill.json").read)
    canonical = Hive::AgentSkills::CanonicalSkill.new

    assert_equal "openclaw", manifest.fetch("platform")
    assert_equal canonical.version, manifest.fetch("skill_version")
    assert_equal canonical.canonical_digest, manifest.fetch("canonical_digest")
    manifest.fetch("files").each do |relative, digest|
      assert_equal Digest::SHA256.hexdigest(root.join(relative).binread), digest, relative
    end
  end

  def test_docs_publish_one_generated_projection_and_derive_version
    readme = README.read

    assert_includes readme, "openclaw skills install #{CLAWHUB_REF}"
    assert_includes readme, CLAWHUB_LISTING
    assert_includes readme, "Do not hand-edit `openclaw/skills/hive/`"
    assert_includes readme, "skills/hive/skill.json"
    assert_includes readme, 'skill_dir="$(pwd)/openclaw/skills/hive"'
    assert_includes readme, 'clawhub skill publish "$skill_dir"'
    assert_includes readme, "--slug hive-cli"
    assert_includes readme, '--version "$skill_version"'
    assert_includes readme, "--dry-run"
    assert_includes readme, "ClawHub publication is staged"
    assert_includes readme, "ClawHub versions are immutable"
    assert_includes readme, "clawhub inspect #{CLAWHUB_REF}"
    assert_includes readme, "separate explicit release request"
    refute_match(/--version\s+\d+\.\d+\.\d+/, readme)
    refute_includes readme, "for skill in openclaw/skills"
    assert_match(/do not create slugs such as\s+`hive-plan`/, readme)
  end

  private

  def read_skill(skill)
    text = ROOT.join(skill, "SKILL.md").read
    match = text.match(/\A---\r?\n(?<frontmatter>.*?)\r?\n---\r?\n(?<body>.*)\z/m)
    refute_nil match, "#{skill} must start with YAML frontmatter"

    [ YAML.safe_load(match[:frontmatter], aliases: false), match[:body] ]
  end

  def projection_text
    root = ROOT.join("hive")
    root.glob("{SKILL.md,references/*.md}").sort.map(&:read).join("\n")
  end
end
