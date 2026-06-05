require "test_helper"
require "yaml"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/generate_name"
require "hive/task_meta"

# Live-claude smoke for U4 display-name generation. Spawns the real `claude`
# binary (the configured `execute` agent) against a tmp git repo and asserts
# that `hive generate-name <target>` populates a non-empty `display_name` in
# meta.yml while leaving `id`/`slug` intact.
#
# This is the plan's U4 "real agent per the no-stub rule" scenario: the
# integration coverage under test/integration uses a fake shell-script agent,
# so the actual CLI-agent → usable-name path is only exercised here, where
# claude is really invoked (no mocked API). Excluded from the default
# `rake test` suite — invoke via `rake smoke`.
class LiveGenerateNameSmokeTest < Minitest::Test
  include HiveTestHelper

  def test_generate_name_populates_display_name_against_real_claude
    # Keep the real HOME so the spawned claude reuses the operator's logged-in
    # session (~/.claude); only HIVE_HOME is isolated. Otherwise claude drops
    # to its login screen and the run stalls.
    with_tmp_global_config(home: ENV.fetch("HOME")) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        configure_execute_agent(dir, "claude")
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "add a contributing note").call }

        folder = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        before = Hive::TaskMeta.read(folder)

        name = nil
        capture_io { name = Hive::Commands::GenerateName.new(folder).call }

        refute_nil name, "generate-name must return a name from the real claude agent"
        refute_empty name.strip, "the generated display_name must be non-empty"

        after = Hive::TaskMeta.read(folder)
        assert_equal name, after[:display_name],
                     "meta.yml display_name must match the generated name"
        refute_nil after[:display_name], "display_name must be populated after generate-name"
        refute_empty after[:display_name].strip, "display_name in meta.yml must be non-empty"
        assert_equal before[:id], after[:id], "generate-name must not touch the task id"
        assert_equal before[:slug], after[:slug], "generate-name must not touch the slug"
      end
    end
  end

  private

  # Point the project's execute-stage agent at the real `claude` CLI (default
  # bin on PATH). U4 generation resolves the `execute` profile, and rendered
  # templates default it to codex; this smoke test exercises the real claude
  # agent path, so it must pin the agent to claude.
  def configure_execute_agent(dir, agent)
    config_path = File.join(dir, ".hive-state", "config.yml")
    cfg = YAML.safe_load(File.read(config_path)) || {}
    cfg["execute"] ||= {}
    cfg["execute"]["agent"] = agent
    File.write(config_path, cfg.to_yaml)
  end
end
