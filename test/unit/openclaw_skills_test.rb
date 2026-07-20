require "test_helper"
require "pathname"
require "yaml"

class OpenClawSkillsTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../openclaw/skills").expand_path
  HOMEPAGE = "https://github.com/ivankuznetsov/hive"
  CLAWHUB_SLUG = "hive-cli"
  CLAWHUB_REF = "@ivankuznetsov/#{CLAWHUB_SLUG}"
  CLAWHUB_DESCRIPTION = "Operate Hive's folder-based coding-agent workflows from OpenClaw: " \
                        "guided CLI setup, reviewed workflow packages, task pipelines, " \
                        "patrols, web/TUI status, and consent-gated administration."

  def test_only_umbrella_skill_is_published_through_clawhub
    actual = ROOT.glob("*/SKILL.md").map { |path| path.dirname.basename.to_s }.sort

    assert_equal [ "hive" ], actual
  end

  def test_umbrella_frontmatter_supports_setup_before_hive_is_installed
    metadata, _body = read_skill("hive")
    openclaw_metadata = metadata.fetch("metadata").fetch("openclaw")

    assert_equal "hive", metadata.fetch("name")
    assert_equal CLAWHUB_DESCRIPTION, metadata.fetch("description")
    assert_equal "0.1.3", metadata.fetch("version")
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
    assert_includes body, "openclaw skills install #{CLAWHUB_REF}"
    assert_includes body, "/hive new ."
    assert_includes body, "/hive plan <task-slug>"
    assert_includes body, "/hive develop <task-slug>"
    assert_includes body, "/hive review <task-slug>"
    assert_includes body, "/hive web"
    assert_includes body, "/hive tui"
    assert_includes body, "/hive setup-agents"
    assert_includes body, "/hive workflow install"
    assert_includes body, "/hive patrol"
    assert_includes body, "/hive refactor-patrol"
    assert_includes body, "/hive digest"
    assert_includes body, "/hive bench submit"
    assert_includes body, "/hive wiki compile-log --check"
    assert_includes body, "wiki/log.d/<timestamp>-<slug>.md"
    assert_includes body, "hive --version"
    assert_includes body, "hv --version"
    assert_includes body, "brew install ivankuznetsov/hive/hive"
    assert_includes body, "yay -S --needed hive-bin"
    assert_includes body, "paru -S --needed hive-bin"
    assert_includes body, "v0.6.4/install.sh"
    refute_match(/(?:yay|paru)[^\n]*--noconfirm/, body)
    assert_includes body, "daemon install"
    assert_includes body, "setup --no-init --json"
    assert_includes body, "slash-command text after `/hive` as arguments for `hive_cmd`"
    assert_includes body, '"${hive_cmd}" --help'
    assert_includes body, "Pass arguments safely"
  end

  def test_umbrella_skill_keeps_package_install_and_initial_enrollment_interactive
    _metadata, body = read_skill("hive")
    guided_setup = section(body, "## Guided Setup")

    assert_includes guided_setup, "yay -S --needed hive-bin"
    assert_includes guided_setup, "paru -S --needed hive-bin"
    assert_includes guided_setup, '"${hive_cmd}" setup --no-init --json'
    assert_match(/run in their own real terminal/i, guided_setup)
    assert_match(/Do not execute it through a non-TTY tool\s+call/i, guided_setup)
    assert_match(/Initial project enrollment.*separate, consent-gated step/im, guided_setup)
    assert_match(/hive init \..*their own real terminal/im, guided_setup)
    assert_match(/non-TTY.*defaults/im, guided_setup)
    assert_match(/subscription.*(?:pull requests?|PRs)|(?:pull requests?|PRs).*subscription/im, guided_setup)
    refute_match(/(?:yay|paru)[^\n]*--noconfirm/, guided_setup)
  end

  def test_umbrella_skill_documents_custom_workflows
    _metadata, body = read_skill("hive")
    workflows = section(body, "## Custom Workflows")

    assert_includes workflows, "--workflow"
    assert_includes workflows, "writing"
    assert_includes workflows, "feedback triage"
    assert_includes workflows, "hive workflow new"
    assert_includes workflows, "hive workflow install honeycomb/<name> --dry-run --json"
    assert_includes workflows, "hive workflow install honeycomb/<name> --yes --json"
    assert_includes workflows, "hive workflow list --json"
    assert_includes workflows, "hive workflow update <name> --dry-run --json"
    assert_includes workflows, "hive workflow update <name> --yes --json"
    assert_includes workflows, "hive workflow remove <name> --dry-run --json"
    assert_includes workflows, "hive workflow remove <name> --yes --json"
    assert_match(/explicit(?: user approval|ly approves)/i, workflows)
    assert_includes workflows, "--allow-escalation"
    assert_match(/do not infer (?:that|escalation) authorization/i, workflows)

    preview_index = workflows.index("hive workflow install honeycomb/<name> --dry-run --json")
    approval_index = workflows.match(/explicit(?: user approval|ly approves)/i).begin(0)
    execution_index = workflows.index("hive workflow install honeycomb/<name> --yes --json")
    assert_operator preview_index, :<, approval_index
    assert_operator approval_index, :<, execution_index
  end

  def test_umbrella_skill_documents_machine_readable_setup_agents_approval
    _metadata, body = read_skill("hive")

    assert_includes body, "hive setup-agents --json"
    assert_includes body, "hive setup-agents --yes --json"
    assert_match(
      /hive setup-agents --json.*(?:approves?|approval).*hive setup-agents --yes --json/im,
      body
    )
    assert_match(/consent-required response and nonzero\s+exit are expected/im, body)
  end

  def test_umbrella_skill_documents_daemon_auto_advance
    _metadata, body = read_skill("hive")

    [
      "auto-advance",
      "previously approved enrollment",
      "hive daemon status --json",
      "next:",
      "manual fallback or recovery command",
      "do not execute the printed command",
      "needs_input",
      "Safety Boundaries"
    ].each do |literal|
      assert_includes body, literal
    end
  end

  def test_umbrella_skill_documents_bounded_patrol_tiers
    _metadata, body = read_skill("hive")
    patrol = section(body, "## Patrol And Architecture Patrol")

    [
      "opt-in",
      "subscription",
      "patrol.mode",
      "low",
      "medium",
      "high",
      "ultrapatrol",
      "2x",
      "shared daily ceiling",
      "hive tui",
      "token",
      "human-only"
    ].each do |literal|
      assert_includes patrol, literal
    end

    assert_includes patrol, "explicit user confirmation"
    assert_match(/human-only interactive handoff/i, patrol)
    assert_match(/must not claim exact\s+token totals/im, patrol)
    assert_match(/no machine-readable token-stat\s+command/im, patrol)
  end

  def test_umbrella_skill_guards_destructive_and_blocking_commands
    _metadata, body = read_skill("hive")
    safety = section(body, "## Safety Boundaries")

    %w[
      drop
      uninstall
      update
      forget
      prune
      migrate
    ].each do |verb|
      assert_includes safety, verb
    end

    assert_match(/Read-only inspection includes[^.]*`metrics`/m, safety)

    [
      "daemon stop",
      "daemon disable --all",
      "daemon install --force",
      "bot stop",
      "bot install --force",
      "markers clear",
      "approve --force"
    ].each do |command|
      assert_includes safety, command
    end

    assert_includes safety, "workflow install/update/remove/publish"
    assert_includes safety, "`setup-agents`"
    assert_includes safety, "hive patrol ... --dry-run"
    assert_includes safety, "hive refactor-patrol ... --dry-run"
    assert_match(/Both remain consent-gated patrol starts/i, safety)
    assert_includes safety, "outbound `digest`/`bench submit`"
    refute_match(/Read-only inspection includes[^.]*patrol/im, safety)

    assert_includes safety, "restate the effect"
    assert_includes safety, "explicit user confirmation"
    assert_includes safety, "hive daemon start --detach"
    assert_includes safety, "hive daemon tail"
    assert_includes safety, "hive bot start --foreground"
    assert_includes safety, "hive bot tail"
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

  def test_umbrella_skill_avoids_direct_runtime_and_service_mutation
    _metadata, body = read_skill("hive")

    assert_includes body, "Never patch an installed Hive runtime"
    assert_includes body, "Hive-native setup and repair commands"
    refute_includes body, "patch-in-place"
    refute_includes body, "cat > ~/.config/systemd"
    refute_includes body, "systemctl --user edit"
    refute_includes body, "mkdir -p ~/.config/systemd"
    refute_includes body, "systemctl --user daemon-reload"
    refute_includes body, "systemctl --user restart hive-daemon.service"
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
      "bounded polling",
      "timeout",
      "7-artifacts",
      "8-finalize",
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
      "command -v hive",
      "hive doctor --json",
      "hive setup --no-init --json",
      "hive daemon install --force --json",
      "hive daemon status --json"
    ].each do |literal|
      assert_includes diagnostics, literal
    end
  end

  def test_openclaw_docs_publish_only_the_single_hive_cli_slug
    readme = Pathname.new(__dir__).join("../../openclaw/README.md").expand_path.read

    assert_includes readme, "openclaw skills install #{CLAWHUB_REF}"
    assert_includes readme, 'skill_dir="$(pwd)/openclaw/skills/hive"'
    assert_includes readme, 'clawhub skill publish "$skill_dir"'
    assert_includes readme, "--slug #{CLAWHUB_SLUG}"
    assert_includes readme, "--version 0.1.3"
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
