require "test_helper"
require "pathname"
require "yaml"

class OpenClawSkillsTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../openclaw/skills").expand_path
  HOMEPAGE = "https://github.com/ivankuznetsov/hive"
  CLAWHUB_SLUG = "hive-cli"
  CLAWHUB_DESCRIPTION = "Run Hive's folder-based coding-agent pipeline from OpenClaw: " \
                        "guided CLI setup, project init, task creation, " \
                        "plan/develop/review workflows, status, daemon, " \
                        "and guarded admin commands."

  def test_only_umbrella_skill_is_published_through_clawhub
    actual = ROOT.glob("*/SKILL.md").map { |path| path.dirname.basename.to_s }.sort

    assert_equal [ "hive" ], actual
  end

  def test_umbrella_frontmatter_supports_setup_before_hive_is_installed
    metadata, _body = read_skill("hive")
    openclaw_metadata = metadata.fetch("metadata").fetch("openclaw")

    assert_equal "hive", metadata.fetch("name")
    assert_equal CLAWHUB_DESCRIPTION, metadata.fetch("description")
    assert_equal "0.1.1", metadata.fetch("version")
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
    assert_includes body, "openclaw skills install #{CLAWHUB_SLUG}"
    assert_includes body, "/hive new ."
    assert_includes body, "/hive plan <task-slug>"
    assert_includes body, "/hive develop <task-slug>"
    assert_includes body, "/hive review <task-slug>"
    assert_includes body, "/hive web"
    assert_includes body, "/hive wiki compile-log --check"
    assert_includes body, "wiki/log.d/<timestamp>-<slug>.md"
    assert_includes body, "hive --version"
    assert_includes body, "hv --version"
    assert_includes body, "brew install ivankuznetsov/hive/hive"
    assert_includes body, "yay -S --noconfirm --needed hive-bin"
    assert_includes body, "v0.2.0/install.sh"
    assert_includes body, "daemon install"
    assert_includes body, "setup --json"
    assert_includes body, "slash-command text after `/hive` as arguments for `hive_cmd`"
    assert_includes body, '"${hive_cmd}" --help'
    assert_includes body, "Pass arguments safely"
  end

  def test_umbrella_skill_documents_daemon_auto_advance
    _metadata, body = read_skill("hive")

    [
      "auto-advance",
      "normal OpenClaw setups",
      "hive daemon status --json",
      "next:",
      "manual fallback or recovery command",
      "do not ask before ordinary stage advancement",
      "needs_input",
      "Safety Boundaries"
    ].each do |literal|
      assert_includes body, literal
    end
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

  def test_umbrella_skill_classifies_recovery_markers
    _metadata, body = read_skill("hive")
    recovery = section(body, "## Marker Recovery")
    safety = section(body, "## Safety Boundaries")

    assert_operator body.index(/^## Safety Boundaries$/), :<, body.index(/^## Marker Recovery$/)

    [
      "## Marker Recovery",
      "hive status --json",
      "hive daemon status --json",
      "hive daemon start --detach",
      "claude stop hook did not signal completion",
      "fix_failed",
      "limits_reached",
      "retry_after",
      "agent_working",
      "REVIEW_ERROR",
      "ERROR",
      "let the healer",
      "ask before",
      "markers clear",
      "--match-attr marker_id=<id>"
    ].each do |literal|
      assert_includes recovery, literal
    end

    # Anchor decision entry 6 on its rule-specific phrase so the terminal/manual
    # `ERROR` guidance is pinned independently of the "ERROR" substring inside
    # "REVIEW_ERROR" (which the bare literal above matches trivially).
    assert_includes recovery, "Terminal/manual `ERROR`"

    assert_includes safety, "markers clear"
    assert_includes safety, "restate the effect"
    assert_includes safety, "explicit user confirmation"
  end

  def test_umbrella_skill_documents_local_dogfood_workflow
    _metadata, body = read_skill("hive")
    dogfood = section(body, "## Local Dogfood")
    safety = section(body, "## Safety Boundaries")

    assert_operator body.index(/^## Local Dogfood$/), :<, body.index(/^## Safety Boundaries$/)

    [
      "gh pr view <number> --json state,mergedAt,baseRefName,statusCheckRollup",
      "command -v hive",
      'readlink -f "$(command -v hive)"',
      "hive daemon status --json",
      "systemctl --user status hive-daemon.service --no-pager",
      "preserve dirty worktree",
      "do not bump or release",
      "rollback",
      # Pin the numbered Rollback step heading, not just the prose "rollback"
      # token, so a future prose reword cannot silently drop the section.
      "8. Rollback:"
    ].each do |literal|
      assert_includes dogfood, literal
    end

    # The dogfood restart guidance must not weaken or relocate the Safety
    # Boundaries confirmation contract, so pin these literals to that section.
    [
      "restate the effect",
      "daemon stop"
    ].each do |literal|
      assert_includes safety, literal
    end
  end

  def test_umbrella_skill_documents_status_bundle_playbook
    _metadata, body = read_skill("hive")
    status_bundle = section(body, "## Status Bundle")

    assert_operator body.index(/^## Status Bundle$/), :<, body.index(/^## Safety Boundaries$/)

    [
      "hive daemon status --json",
      "hive status --json",
      "systemctl --user status hive-daemon.service",
      "gh pr checks"
    ].each do |command|
      assert_includes status_bundle, command
    end

    [
      "stage",
      "marker",
      "action",
      "PR URL",
      "CI status",
      "live PID",
      "held/retry",
      "suggested command"
    ].each do |field|
      assert_includes status_bundle, field
    end

    assert_includes status_bundle, "read-only"
  end

  def test_umbrella_skill_documents_watch_selected_tasks
    _metadata, body = read_skill("hive")

    [
      "## Watch Selected Tasks",
      "hive status --json",
      "jq",
      "HIVE_WATCH_INTERVAL",
      "HIVE_WATCH_TIMEOUT",
      "claude_pid_alive",
      "retry_after",
      "pr_url",
      "7-artifacts",
      "8-finalize",
      "trap",
      "Ctrl-C is safe",
      "never kills Hive agents",
      "never clears markers",
      "never advances stages"
    ].each do |literal|
      assert_includes body, literal
    end
  end

  def test_umbrella_skill_documents_daemon_diagnostics_and_repair
    _metadata, body = read_skill("hive")
    diagnostics = section(body, "## Daemon Diagnostics And Repair")

    diagnostics_index = body.index(/^## Daemon Diagnostics And Repair$/)
    safety_index = body.index(/^## Safety Boundaries$/)
    assert_operator diagnostics_index, :<, safety_index
    between = body[diagnostics_index...safety_index].sub(/\A## Daemon Diagnostics And Repair\n/, "")
    refute_match(/^## /, between,
      "## Daemon Diagnostics And Repair must sit immediately before ## Safety Boundaries")

    [
      "systemctl --user cat hive-daemon.service",
      "systemctl --user show hive-daemon.service -p Environment",
      "command -v hive",
      "HIVE_BIN",
      "/usr/bin/hive",
      "~/.local/bin/hive",
      "GEM_HOME",
      "GEM_PATH",
      "PATH",
      "cannot load such file -- erb (LoadError)",
      "ruby-erb",
      "sudo pacman -S ruby-erb",
      "gem install --user-install erb",
      "systemctl --user edit hive-daemon.service",
      "systemctl --user daemon-reload",
      "systemctl --user restart hive-daemon.service",
      "hive daemon status --json"
    ].each do |literal|
      assert_includes diagnostics, literal
    end
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

  def section(body, heading)
    start_index = body.index(/^#{Regexp.escape(heading)}$/)
    refute_nil start_index, "#{heading} section must exist"

    remainder = body[start_index..]
    next_heading_index = remainder.index(/\n## /)
    next_heading_index ? remainder[0...next_heading_index] : remainder
  end
end
