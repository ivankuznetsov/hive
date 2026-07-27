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
        assert_equal File.basename(project_root), payload.dig("global_registration", "name")
        assert_equal "available", payload.dig("global_registration", "status")
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

  def test_execute_does_not_install_the_llm_wiki_scheduler
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        installs = []
        with_replaced_singleton_method(
          Hive::LlmWikiBootstrap::Scheduler, :install, ->(root) { installs << root }
        ) do
          capture_io do
            Hive::Commands::Init.new(
              project_root, new_workflow: "editorial", minimal: true,
              agent_skill_preflight: false
            ).call
          end
        end

        assert_empty installs
      end
    end
  end

  def test_interrupted_scaffold_commit_rolls_back_minimal_initialization
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        before = repository_snapshot(project_root)
        replacement = ->(*_args, **_kwargs) { raise Interrupt, "stop" }

        with_replaced_singleton_method(
          Hive::Commands::Workflow, :commit_workflow_scaffold, replacement
        ) do
          assert_raises(Interrupt) do
            Hive::Commands::Init.new(
              project_root, new_workflow: "editorial", minimal: true,
              agent_skill_preflight: false
            ).call
          end
        end

        assert_equal before, repository_snapshot(project_root)
        refute File.exist?(File.join(project_root, ".hive-state"))
        refute Hive::Config.registered_projects.any? { |project|
          File.expand_path(project.fetch("path")) == project_root
        }
      end
    end
  end

  def test_execute_refuses_managed_project_symlinks_without_writing_through_them
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        outside = File.join(File.dirname(project_root), "outside-agents.md")
        File.write(outside, "outside choice\n")
        managed = File.join(project_root, "AGENTS.md")
        File.symlink(outside, managed)
        run!("git", "-C", project_root, "add", "AGENTS.md")
        run!("git", "-C", project_root, "commit", "-m", "track project choice", "--quiet")

        error = assert_raises(Hive::ConfigError) do
          capture_io do
            Hive::Commands::Init.new(
              project_root, new_workflow: "editorial", minimal: true,
              agent_skill_preflight: false
            ).call
          end
        end

        assert_includes error.message, "must not be a symlink"
        assert_equal "outside choice\n", File.read(outside)
        assert File.symlink?(managed)
        refute File.exist?(File.join(project_root, ".hive-state"))
      end
    end
  end

  def test_minimal_refuses_a_dangling_hive_state_symlink
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        hive_state = File.join(project_root, ".hive-state")
        outside = File.join(File.dirname(project_root), "missing-hive-state")
        File.symlink(outside, hive_state)

        error = assert_raises(Hive::AlreadyInitialized) do
          Hive::Commands::Init.new(
            project_root, new_workflow: "editorial", minimal: true, preview: true,
            agent_skill_preflight: false
          ).call
        end

        assert_includes error.message, "fresh target"
        assert File.symlink?(hive_state)
        refute File.exist?(outside)
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
        out, = capture_io do
          assert_raises(Hive::AlreadyInitialized) do
            Hive::Commands::Init.new(
              project_root, minimal: true, new_workflow: "another",
              json: true, agent_skill_preflight: false
            ).call
          end
        end
        payload = JSON.parse(out)
        assert_equal "already_initialized", payload.fetch("error_kind")
        assert_schema_valid("hive-init", payload)
      end
    end
  end

  def test_minimal_rejects_invalid_flag_combinations_and_collisions
    assert_raises(ArgumentError) do
      Hive::Commands::Init.new(".", minimal: :yes)
    end
    assert_raises(Hive::Commands::Workflow::UsageError) do
      Hive::Commands::Init.new(".", preview: true).send(:validate_minimal_arguments!)
    end
    assert_raises(Hive::Commands::Workflow::UsageError) do
      Hive::Commands::Init.new(
        ".", minimal: true, new_workflow: "editorial", refactor_patrol: true
      ).send(:validate_minimal_arguments!)
    end

    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        collision = ->(_id, project_root:) { project_root == File.expand_path(project_root) }
        suggestion = ->(_id, project_root:) { "editorial-2" }
        with_replaced_singleton_method(Hive::Commands::Workflow, :scaffold_collision?, collision) do
          with_replaced_singleton_method(Hive::Commands::Workflow, :available_id, suggestion) do
            error = assert_raises(Hive::Commands::Workflow::UsageError) do
              Hive::Commands::Init.new(
                project_root, minimal: true, new_workflow: "editorial",
                agent_skill_preflight: false
              ).call
            end
            assert_equal "editorial-2", error.suggested_id
          end
        end
      end
    end
  end

  def test_minimal_refuses_to_replace_an_unrelated_same_name_registration
    with_tmp_global_config do
      with_tmp_dir do |root|
        first = File.join(root, "first", "shared")
        second = File.join(root, "second", "shared")
        initialize_git_repo(first)
        initialize_git_repo(second)
        Hive::Config.register_project(name: "shared", path: first)

        out, = capture_io do
          assert_raises(Hive::Commands::Init::ProjectRegistrationCollision) do
            Hive::Commands::Init.new(
              second, minimal: true, preview: true, new_workflow: "editorial",
              json: true, agent_skill_preflight: false
            ).call
          end
        end
        payload = JSON.parse(out)

        assert_equal false, payload.fetch("ok")
        assert_equal "project_name_collision", payload.fetch("error_kind")
        assert_equal first, payload.fetch("existing_path")
        assert_equal first, Hive::Config.find_project("shared").fetch("path")
        schemer = JSONSchemer.schema(
          JSON.parse(File.read(Hive::Schemas.schema_path("hive-init-preview")))
        )
        assert_empty schemer.validate(payload).to_a
      end
    end
  end

  def test_minimal_rechecks_registration_inside_the_locked_write
    with_tmp_global_config do
      with_tmp_dir do |root|
        existing = File.join(root, "existing", "shared")
        target = File.join(root, "target", "shared")
        initialize_git_repo(existing)
        initialize_git_repo(target)

        command = Hive::Commands::Init.new(
          target, minimal: true, new_workflow: "editorial",
          json: true, agent_skill_preflight: false
        )
        original = command.method(:ensure_minimal_registration_available!)
        command.define_singleton_method(:ensure_minimal_registration_available!) do
          original.call
          Hive::Config.register_project(name: "shared", path: existing)
        end

        out, = capture_io do
          assert_raises(Hive::Commands::Init::ProjectRegistrationCollision) { command.call }
        end
        payload = JSON.parse(out)

        assert_equal "project_name_collision", payload.fetch("error_kind")
        assert_equal existing, payload.fetch("existing_path")
        assert_equal existing, Hive::Config.find_project("shared").fetch("path")
        refute File.exist?(File.join(target, ".hive-state"))
        assert_schema_valid("hive-init", payload)
      end
    end
  end

  def test_minimal_json_failures_use_typed_command_envelopes
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        File.write(File.join(project_root, "README.md"), "dirty\n")
        out, = capture_io do
          assert_raises(Hive::Commands::Init::PreconditionError) do
            Hive::Commands::Init.new(
              project_root, minimal: true, new_workflow: "editorial",
              json: true, agent_skill_preflight: false
            ).call
          end
        end
        payload = JSON.parse(out)
        assert_equal "hive-init", payload.fetch("schema")
        assert_equal "dirty_worktree", payload.fetch("error_kind")
        assert_equal false, payload.fetch("preview")
        assert_schema_valid("hive-init", payload)
      end

      with_tmp_git_repo do |project_root|
        out, = capture_io do
          assert_raises(Hive::Commands::Workflow::UsageError) do
            Hive::Commands::Init.new(
              project_root, minimal: true, preview: true, new_workflow: "Bad_ID",
              json: true, agent_skill_preflight: false
            ).call
          end
        end
        payload = JSON.parse(out)
        assert_equal "hive-init-preview", payload.fetch("schema")
        assert_equal "usage", payload.fetch("error_kind")
        assert_equal "Bad_ID", payload.fetch("value")
        assert_schema_valid("hive-init-preview", payload)
      end
    end
  end

  def test_plain_preview_reports_plan_and_broken_pipe_is_harmless
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        out, = capture_io do
          Hive::Commands::Init.new(
            project_root, new_workflow: "editorial", minimal: true, preview: true,
            agent_skill_preflight: false
          ).call
        end
        assert_includes out, "minimal init preview"
        assert_includes out, "workflow: editorial"
        assert_includes out, "automation: disabled"

        command = Hive::Commands::Init.new(
          project_root, new_workflow: "editorial", minimal: true, preview: true,
          agent_skill_preflight: false
        )
        command.define_singleton_method(:minimal_preview_payload) do |_ops, _id|
          { "project_files" => [], "workflow" => "editorial" }
        end
        broken = Object.new
        broken.define_singleton_method(:write) { |_body| raise Errno::EPIPE }
        original = $stdout
        begin
          $stdout = broken
          assert_nil command.send(
            :emit_minimal_preview, Hive::GitOps.new(project_root), "editorial"
          )
        ensure
          $stdout = original
        end
      end
    end
  end

  private

  def initialize_git_repo(path)
    FileUtils.mkdir_p(path)
    run!("git", "-C", path, "init", "-b", "master", "--quiet")
    run!("git", "-C", path, "config", "user.email", "test@example.com")
    run!("git", "-C", path, "config", "user.name", "Test")
    File.write(File.join(path, "README.md"), "test\n")
    run!("git", "-C", path, "add", ".")
    run!("git", "-C", path, "commit", "-m", "initial", "--quiet")
  end

  def assert_schema_valid(name, payload)
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))
    errors = schemer.validate(payload).to_a
    assert_empty errors, "#{name} payload errors: #{errors.map { |error| error['error'] }.inspect}"
  end

  def repository_snapshot(project_root)
    {
      head: run!("git", "-C", project_root, "rev-parse", "HEAD").strip,
      status: run!("git", "-C", project_root, "status", "--porcelain"),
      branches: run!("git", "-C", project_root, "branch", "--format=%(refname:short)")
    }
  end
end
