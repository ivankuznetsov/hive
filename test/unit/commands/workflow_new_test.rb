require "test_helper"
require "json"
require "hive/commands/init"
require "hive/commands/workflow"
require "hive/workflow_selection"
require "hive/workflows/descriptor_parser"
require "hive/workflows/project"

class WorkflowNewTest < Minitest::Test
  include HiveTestHelper

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_scaffolds_blank_workflow_descriptor_and_instruction
    with_initialized_project do |project_root|
      stdout = StringIO.new

      payload = Hive::Commands::Workflow.new!("my-flow", project_root: project_root, stdout: stdout)

      descriptor_path = File.join(project_root, ".hive-state", "workflows", "my-flow.yml")
      instruction_path = File.join(project_root, ".hive-state", "workflows", "my-flow", "work.md")
      assert_equal true, payload.fetch("ok")
      assert_equal "my-flow", payload.fetch("id")
      assert_equal descriptor_path, payload.fetch("descriptor_path")
      assert_equal instruction_path, payload.fetch("instruction_path")
      assert_includes stdout.string, "hive: created workflow my-flow"
      assert_includes stdout.string, "hive new --workflow my-flow"

      assert File.file?(descriptor_path)
      assert_equal "Edit this file to define what the `work` stage should do.\n", File.read(instruction_path)

      workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)
      assert_equal :"my-flow", workflow.id
      assert_equal %w[inbox work done], workflow.stage_names
      assert_equal :inert, workflow.stages[0].kind
      assert_equal :agent, workflow.stages[1].kind
      assert_equal instruction_path, workflow.stages[1].instruction
      assert_nil workflow.stages[1].skill
      assert_equal :inert, workflow.stages[2].kind

      assert_equal :"my-flow", Hive::WorkflowSelection.fetch!("my-flow", project_root: project_root).id
      assert_includes Hive::Workflows.all_stage_dirs, "2-work"

      log = run!("git", "-C", File.join(project_root, ".hive-state"), "log", "--format=%s", "-1").strip
      assert_equal "hive: workflows/my-flow created", log
    end
  end

  def test_json_success_payload
    with_initialized_project do |project_root|
      out, err, status = with_captured_exit do
        Hive::Commands::Workflow.new("new", "json-flow", project_root: project_root, json: true).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_empty err
      payload = JSON.parse(out)
      assert_equal true, payload.fetch("ok")
      assert_equal "json-flow", payload.fetch("id")
      assert_match(%r{/\.hive-state/workflows/json-flow\.yml\z}, payload.fetch("descriptor_path"))
    end
  end

  def test_refuses_to_overwrite_existing_scaffold
    with_initialized_project do |project_root|
      Hive::Commands::Workflow.new!("my-flow", project_root: project_root, stdout: StringIO.new)
      instruction_path = File.join(project_root, ".hive-state", "workflows", "my-flow", "work.md")
      File.write(instruction_path, "custom body\n")

      error = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new!("my-flow", project_root: project_root, stdout: StringIO.new)
      end

      assert_equal Hive::ExitCodes::USAGE, error.exit_code
      assert_includes error.message, "already exists"
      assert_equal "custom body\n", File.read(instruction_path)
    end
  end

  def test_json_error_payload
    with_initialized_project do |project_root|
      out, err, status = with_captured_exit do
        Hive::Commands::Workflow.new("new", "coding", project_root: project_root, json: true).call
      end

      assert_equal Hive::ExitCodes::USAGE, status
      assert_empty err
      payload = JSON.parse(out)
      assert_equal false, payload.fetch("ok")
      assert_equal "UsageError", payload.fetch("error_class")
      assert_equal Hive::ExitCodes::USAGE, payload.fetch("exit_code")
      assert_includes payload.fetch("message"), "reserved"
    end
  end

  def test_rejects_reserved_and_invalid_ids
    with_tmp_dir do |project_root|
      missing = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new!("", project_root: project_root, stdout: StringIO.new)
      end
      assert_includes missing.message, "missing workflow id"

      reserved = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new!("coding", project_root: project_root, stdout: StringIO.new)
      end
      assert_includes reserved.message, "reserved"

      invalid = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new!("Bad_Id", project_root: project_root, stdout: StringIO.new)
      end
      assert_includes invalid.message, "invalid workflow id"
    end
  end

  def test_rolls_back_files_when_generated_descriptor_fails_validation
    with_initialized_project do |project_root|
      error = Hive::ConfigError.new("boom")
      with_replaced_singleton_method(Hive::Workflows::DescriptorParser, :parse_file, lambda { |_path|
        raise error
      }) do
        raised = assert_raises(Hive::ConfigError) do
          Hive::Commands::Workflow.new!("broken-flow", project_root: project_root, stdout: StringIO.new)
        end
        assert_same error, raised
      end

      refute File.exist?(File.join(project_root, ".hive-state", "workflows", "broken-flow.yml"))
      refute File.exist?(File.join(project_root, ".hive-state", "workflows", "broken-flow"))
    end
  end

  def test_call_reports_unknown_subcommand_as_usage
    with_initialized_project do |project_root|
      _out, err, status = with_captured_exit do
        Hive::Commands::Workflow.new("save", "my-flow", project_root: project_root).call
      end

      assert_equal Hive::ExitCodes::USAGE, status
      assert_includes err, "unknown workflow subcommand"
    end
  end

  private

    def with_initialized_project
      with_tmp_global_config do
        with_tmp_git_repo do |project_root|
          capture_io { Hive::Commands::Init.new(project_root).call }
          yield project_root
        end
      end
    end
end
