require "test_helper"
require "hive/cli"
require "pathname"
require "yaml"

class OpenClawSkillsTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../openclaw/skills").expand_path
  HOMEPAGE = "https://github.com/ivankuznetsov/hive"

  # Thor commands that intentionally have no OpenClaw skill. `help` and
  # `tree` are Thor built-ins. `tui` is human-only and rejects --json
  # with EX_USAGE (64). `version` is covered by `hive --version`.
  # Destructive admin verbs (drop/uninstall/update/forget/prune/migrate/
  # metrics) fall back to the umbrella `/hive ...` skill where the agent
  # sees the full command before execution.
  ADMIN_EXCLUDED_COMMANDS = %w[
    drop
    forget
    help
    metrics
    migrate
    prune
    tree
    tui
    uninstall
    update
    version
  ].freeze

  EXPECTED_SKILLS = {
    "hive" => { description: "Drive any Hive CLI workflow from OpenClaw.", command: "hive" },
    "new" => { cli: "new_task", command: "hive new" },
    "brainstorm" => { cli: "brainstorm", command: "hive brainstorm" },
    "plan" => { cli: "plan", command: "hive plan" },
    "work" => { cli: "develop", command: "hive develop" },
    "open-pr" => { cli: "open_pr", command: "hive open-pr" },
    "ce-review" => { cli: "review", command: "hive review" },
    "artifacts" => { cli: "artifacts", command: "hive artifacts" },
    "finalize" => { cli: "finalize", command: "hive finalize" },
    "archive" => { cli: "archive", command: "hive archive" },
    "hive-status" => { cli: "status", command: "hive status" },
    "findings" => { cli: "findings", command: "hive findings" },
    "accept-finding" => { cli: "accept_finding", command: "hive accept-finding" },
    "reject-finding" => { cli: "reject_finding", command: "hive reject-finding" },
    "approve" => { cli: "approve", command: "hive approve" },
    "run" => { cli: "run_task", command: "hive run" },
    "markers" => { cli: "markers", command: "hive markers" },
    "rebase-status" => { cli: "rebase_status", command: "hive rebase-status" },
    "doctor" => { cli: "doctor", command: "hive doctor" },
    "daemon" => { cli: "daemon", command: "hive daemon" },
    "bot" => { cli: "bot", command: "hive bot" },
    "init" => { cli: "init", command: "hive init" }
  }.freeze

  def test_skill_directories_match_supported_openclaw_surface
    actual = ROOT.children.select(&:directory?).map { |path| path.basename.to_s }.sort

    assert_equal EXPECTED_SKILLS.keys.sort, actual
  end

  # Drift check: every Thor command in lib/hive/cli.rb must either ship a
  # SKILL.md (mapped via EXPECTED_SKILLS) or be listed in
  # ADMIN_EXCLUDED_COMMANDS. Reading from `Hive::CLI.all_commands.keys`
  # — not from a hand-maintained list — is what makes this an actual
  # drift guard. Add a new workflow verb to lib/hive/cli.rb without a
  # corresponding skill and this test goes red.
  def test_every_non_admin_thor_command_has_a_skill
    thor_commands = Hive::CLI.all_commands.keys.sort
    mapped_clis = EXPECTED_SKILLS.values.filter_map { |v| v[:cli] }.sort

    uncovered = thor_commands - mapped_clis - ADMIN_EXCLUDED_COMMANDS
    assert_empty uncovered,
                 "every non-admin Thor command must have a SKILL.md mapped in EXPECTED_SKILLS " \
                 "(or be listed in ADMIN_EXCLUDED_COMMANDS). Missing: #{uncovered.inspect}"

    stale_exclusions = ADMIN_EXCLUDED_COMMANDS - thor_commands
    assert_empty stale_exclusions,
                 "ADMIN_EXCLUDED_COMMANDS references non-existent Thor commands: #{stale_exclusions.inspect}"
  end

  def test_skill_frontmatter_and_bodies_are_valid
    EXPECTED_SKILLS.each do |skill, expected|
      metadata, body = read_skill(skill)

      assert_equal skill, metadata.fetch("name")
      assert_equal expected.fetch(:description) { Hive::CLI.all_commands.fetch(expected.fetch(:cli)).description },
                   metadata.fetch("description")
      assert_equal "0.1.0", metadata.fetch("version")
      assert_equal true, metadata.fetch("user-invocable")
      assert_equal HOMEPAGE, metadata.dig("metadata", "openclaw", "homepage")
      assert_equal [ "hive" ], metadata.dig("metadata", "openclaw", "requires", "bins"),
                   "#{skill} must declare hive in metadata.openclaw.requires.bins"

      assert_includes body, "command -v hive", "#{skill} must fail loudly when hive is missing"
      assert_includes body, expected.fetch(:command), "#{skill} must document its CLI dispatch"
      assert_includes body, "Pass arguments safely", "#{skill} must avoid shell interpolation"
    end
  end

  def read_skill(skill)
    text = ROOT.join(skill, "SKILL.md").read
    match = text.match(/\A---\r?\n(?<frontmatter>.*?)\r?\n---\r?\n(?<body>.*)\z/m)
    refute_nil match, "#{skill} must start with YAML frontmatter"

    [ YAML.safe_load(match[:frontmatter], aliases: false), match[:body] ]
  end
end
