require "test_helper"
require "pathname"
require "yaml"

class OpenClawSkillsTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../openclaw/skills").expand_path
  HOMEPAGE = "https://github.com/ivankuznetsov/hive"
  CLAWHUB_SLUG = "hive-cli"

  def test_only_umbrella_skill_is_published_through_clawhub
    actual = ROOT.glob("*/SKILL.md").map { |path| path.dirname.basename.to_s }.sort

    assert_equal [ "hive" ], actual
  end

  def test_umbrella_frontmatter_supports_setup_before_hive_is_installed
    metadata, _body = read_skill("hive")
    openclaw_metadata = metadata.fetch("metadata").fetch("openclaw")

    assert_equal "hive", metadata.fetch("name")
    assert_equal "Install, set up, or drive any Hive CLI workflow from OpenClaw.", metadata.fetch("description")
    assert_equal "0.1.0", metadata.fetch("version")
    assert_equal true, metadata.fetch("user-invocable")
    assert_equal HOMEPAGE, openclaw_metadata.fetch("homepage")
    assert_equal true, openclaw_metadata.fetch("always"), "umbrella skill must remain visible for setup"
    refute openclaw_metadata.dig("requires", "bins"), "umbrella skill must not be gated before setup"

    installer = openclaw_metadata.fetch("install").find { |entry| entry.fetch("id") == "homebrew" }
    refute_nil installer, "umbrella skill must expose macOS dependency installer metadata"
    assert_equal "brew", installer.fetch("kind")
    assert_equal "ivankuznetsov/hive/hive", installer.fetch("formula")
    assert_equal [ "hive" ], installer.fetch("bins")
  end

  def test_umbrella_skill_guides_install_init_and_cli_dispatch
    _metadata, body = read_skill("hive")

    assert_includes body, "/hive setup"
    assert_includes body, "/hive install"
    assert_includes body, "/hive bootstrap"
    assert_includes body, "hive --version"
    assert_includes body, "hv --version"
    assert_includes body, "brew install ivankuznetsov/hive/hive"
    assert_includes body, "yay -S --noconfirm --needed hive-bin"
    assert_includes body, "v0.2.0/install.sh"
    assert_includes body, "daemon install"
    assert_includes body, "init . --json </dev/null"
    assert_includes body, "slash-command text after `/hive` as arguments for `hive_cmd`"
    assert_includes body, '"${hive_cmd}" --help'
    assert_includes body, "Pass arguments safely"
  end

  def test_umbrella_skill_guards_destructive_and_blocking_commands
    _metadata, body = read_skill("hive")

    %w[
      drop
      uninstall
      update
      forget
      prune
      migrate
      metrics
    ].each do |verb|
      assert_includes body, verb
    end

    [
      "daemon stop",
      "daemon disable --all",
      "daemon install --force",
      "bot stop",
      "bot install --force",
      "markers clear",
      "approve --force"
    ].each do |command|
      assert_includes body, command
    end

    assert_includes body, "restate the effect"
    assert_includes body, "explicit user confirmation"
    assert_includes body, "hive daemon start --detach"
    assert_includes body, "hive daemon tail"
    assert_includes body, "hive bot start --foreground"
    assert_includes body, "hive bot tail"
  end

  def test_openclaw_docs_publish_only_the_single_hive_cli_slug
    readme = Pathname.new(__dir__).join("../../openclaw/README.md").expand_path.read

    assert_includes readme, "openclaw skills install #{CLAWHUB_SLUG}"
    assert_includes readme, "clawhub skill publish openclaw/skills/hive"
    assert_includes readme, "--slug #{CLAWHUB_SLUG}"
    assert_includes readme, "do not publish folders"
    assert_includes readme, "hive-plan"
    refute_includes readme, "for skill in openclaw/skills"
    refute_includes readme, "Planned ClawHub Slugs"
  end

  def read_skill(skill)
    text = ROOT.join(skill, "SKILL.md").read
    match = text.match(/\A---\r?\n(?<frontmatter>.*?)\r?\n---\r?\n(?<body>.*)\z/m)
    refute_nil match, "#{skill} must start with YAML frontmatter"

    [ YAML.safe_load(match[:frontmatter], aliases: false), match[:body] ]
  end
end
