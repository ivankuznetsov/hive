require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/init"
require "hive/commands/workflow"

class InitMinimalTest < Minitest::Test
  include HiveTestHelper

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_preview_is_machine_readable_and_leaves_every_target_unchanged
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        before = repository_snapshot(project_root)
        global_path = Hive::Config.global_config_path
        global_before = File.exist?(global_path) ? File.binread(global_path) : nil

        out, err = capture_io do
          Hive::Commands::Init.new(
            project_root, new_workflow: "editorial", minimal: true, preview: true,
            json: true, agent_skill_preflight: false
          ).call
        end
        payload = JSON.parse(out)

        assert_empty err
        assert_equal before, repository_snapshot(project_root)
        refute File.exist?(File.join(project_root, ".hive-state"))
        assert_equal global_before, File.exist?(global_path) ? File.binread(global_path) : nil
        assert_equal true, payload.fetch("preview")
        assert_equal true, payload.fetch("minimal")
        assert_equal "editorial", payload.fetch("workflow")
        assert_equal false, payload.dig("services", "daemon_install")
        assert_equal false, payload.dig("background_automation", "patrol")
        assert_equal true, payload.dig("context_integration", "llm_wiki")
        schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-init-preview"))))
        assert_empty schemer.validate(payload).to_a
      end
    end
  end

  def test_execute_uses_same_minimal_profile_and_scaffolds_loadable_workflow
    with_tmp_global_config do |global_root|
      with_tmp_git_repo do |project_root|
        out, err = capture_io do
          Hive::Commands::Init.new(
            project_root, new_workflow: "editorial", minimal: true,
            json: true, agent_skill_preflight: false
          ).call
        end
        payload = JSON.parse(out)

        assert_empty err
        assert_equal true, payload.fetch("minimal")
        init_schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-init"))))
        assert_empty init_schemer.validate(payload).to_a
        config = Hive::Config.load(project_root)
        assert_equal "editorial", config.fetch("default_workflow")
        assert_equal "off", config.dig("patrol", "mode")
        assert_equal false, config.dig("refactor_patrol", "enabled")
        assert_equal false, config.dig("review", "adhoc", "fix")
        assert_equal false, config.dig("daemon", "enabled")
        assert_equal false, config.dig("babysitter", "enabled")
        global_config = YAML.safe_load(File.read(File.join(global_root, "config.yml")))
        refute global_config.key?("daemon"), "minimal init must not install or persist daemon autostart"
        refute File.exist?(File.join(global_root, ".config", "systemd", "user"))

        validation = Hive::Commands::Workflow.new(
          "validate", "editorial", project_root: project_root, json: false, stdout: StringIO.new
        ).call!
        assert_equal true, validation.fetch("valid")
      end
    end
  end

  def test_minimal_rejects_force_missing_workflow_and_initialized_target
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        assert_raises(Hive::Commands::Workflow::UsageError) do
          Hive::Commands::Init.new(project_root, minimal: true, force: true, new_workflow: "editorial").call
        end
        assert_raises(Hive::Commands::Workflow::UsageError) do
          Hive::Commands::Init.new(project_root, minimal: true).call
        end

        capture_io do
          Hive::Commands::Init.new(
            project_root, minimal: true, new_workflow: "editorial", agent_skill_preflight: false
          ).call
        end
        assert_raises(Hive::AlreadyInitialized) do
          Hive::Commands::Init.new(
            project_root, minimal: true, new_workflow: "another", agent_skill_preflight: false
          ).call
        end
      end
    end
  end

  private

  def repository_snapshot(project_root)
    {
      head: run!("git", "-C", project_root, "rev-parse", "HEAD").strip,
      status: run!("git", "-C", project_root, "status", "--porcelain"),
      branches: run!("git", "-C", project_root, "branch", "--format=%(refname:short)")
    }
  end
end
