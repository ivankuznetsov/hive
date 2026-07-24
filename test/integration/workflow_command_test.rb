require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/init"
require "hive/commands/workflow"
require "hive/commands/workflow/validate"

class WorkflowCommandTest < Minitest::Test
  include HiveTestHelper

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_validate_reports_exact_editorial_graph_without_writing
    with_initialized_project do |project_root|
      descriptor = write_editorial_workflow(project_root)
      before = project_snapshot(project_root)
      before_head = state_head(project_root)
      stdout = StringIO.new

      payload = Hive::Commands::Workflow.new(
        "validate", "editorial", project_root: project_root, json: true, stdout: stdout
      ).call!

      assert_equal before, project_snapshot(project_root)
      assert_equal before_head, state_head(project_root)
      assert_equal true, payload.fetch("valid")
      assert_equal "authored", payload.fetch("origin")
      assert_equal descriptor, payload.fetch("descriptor_path")
      assert_equal %w[research draft approval], payload.fetch("stages").map { |row| row.fetch("name") }
      assert_equal %w[research draft], payload.fetch("automatic_edges").map { |row| row.fetch("from") }
      assert_equal [
        [ "approval", "approve", true, nil ],
        [ "approval", "reject", false, "draft" ]
      ], payload.fetch("human_outcomes").map { |row|
        [ row.fetch("stage"), row.fetch("name"), row.fetch("complete"), row["to"] ]
      }

      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-workflow-validate"))))
      assert_empty schemer.validate(payload).to_a
    end
  end

  def test_validate_rejects_missing_instruction_without_mutation
    with_initialized_project do |project_root|
      descriptor = write_editorial_workflow(project_root)
      File.delete(File.join(File.dirname(descriptor), "editorial", "draft.md"))
      before = project_snapshot(project_root)
      before_head = state_head(project_root)

      out, err, status = with_captured_exit do
        Hive::Commands::Workflow.new(
          "validate", "editorial", project_root: project_root, json: true
        ).call
      end

      assert_equal Hive::ExitCodes::CONFIG, status
      assert_empty err
      payload = JSON.parse(out)
      assert_equal false, payload.fetch("valid")
      assert_includes payload.fetch("message"), "draft.md"
      assert_equal before, project_snapshot(project_root)
      assert_equal before_head, state_head(project_root)
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-workflow-validate"))))
      assert_empty schemer.validate(payload).to_a
    end
  end

  def test_validate_loads_built_in_through_project_resolution
    with_initialized_project do |project_root|
      payload = Hive::Commands::Workflow.new(
        "validate", "coding", project_root: project_root, json: false, stdout: StringIO.new
      ).call!

      assert_equal "built_in", payload.fetch("origin")
      assert_nil payload.fetch("descriptor_path")
      assert_equal Hive::Workflows::Coding::DESCRIPTOR.stage_names,
                   payload.fetch("stages").map { |row| row.fetch("name") }
    end
  end

  def test_validate_never_calls_the_production_project_config_loader
    with_initialized_project do |project_root|
      write_editorial_workflow(project_root)
      forbidden = lambda do |_root|
        raise "strict read-only validation called Config.load"
      end

      with_replaced_singleton_method(Hive::Config, :load, forbidden) do
        payload = Hive::Commands::Workflow::Validate.new(
          "editorial", project_root: project_root, stdout: StringIO.new
        ).call!
        assert_equal true, payload.fetch("valid")
        assert_equal "authored", payload.fetch("origin")
      end
    end
  end

  def test_validate_rejects_invalid_id_and_unreadable_instruction
    with_initialized_project do |project_root|
      error = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow::Validate.new(
          "Not Valid", project_root: project_root
        ).call!
      end
      assert_includes error.message, "invalid workflow id"

      instruction = File.join(project_root, "missing.md")
      stage = Struct.new(:instruction, :name).new(instruction, "draft")
      workflow = [ stage ]
      workflow.define_singleton_method(:id) { :editorial }
      validator = Hive::Commands::Workflow::Validate.new(
        "editorial", project_root: project_root
      )
      error = assert_raises(Hive::ConfigError) do
        validator.send(:validate_instruction_paths!, workflow)
      end
      assert_includes error.message, "missing instruction"
    end
  end

  def test_validate_reports_managed_origin_and_plain_summary
    with_initialized_project do |project_root|
      stdout = StringIO.new
      validator = Hive::Commands::Workflow::Validate.new(
        "managed-flow", project_root: project_root, stdout: stdout
      )
      validator.instance_variable_set(:@descriptor_path, nil)
      assert_equal "managed", validator.send(:origin)

      payload = {
        "stages" => [ { "name" => "work" } ]
      }
      validator.send(:emit, payload)
      assert_includes stdout.string, "managed-flow is valid (managed)"
      assert_includes stdout.string, "stages: work"
    end
  end

  def test_validate_resolves_managed_workflow_through_no_write_selection
    with_initialized_project do |project_root|
      workflow = Hive::Workflows::Registry.default
      fake_store = Object.new
      test = self
      fake_store.define_singleton_method(:selected_read_only) do |name|
        test.assert_equal "managed-flow", name
        {
          "source_commit" => "a" * 40,
          "manifest_digest" => "b" * 64,
          "configuration_digest" => "c" * 64
        }
      end
      fake_store.define_singleton_method(:workflow) do |name, _commit, _manifest, **options|
        test.assert_equal "managed-flow", name
        test.assert_equal false, options.fetch(:verify_profiles)
        workflow
      end

      with_replaced_singleton_method(
        Hive::WorkflowPackage::ManagedStore, :new, ->(_state) { fake_store }
      ) do
        payload = Hive::Commands::Workflow::Validate.new(
          "managed-flow", project_root: project_root, stdout: StringIO.new
        ).call!
        assert_equal "managed", payload.fetch("origin")
      end
    end
  end

  def test_workflow_maps_unknown_workflow_to_usage
    command = Hive::Commands::Workflow.new(
      "validate", "missing", project_root: ".", stdout: StringIO.new
    )
    error = Hive::Workflows::UnknownWorkflow.new("missing")

    assert_equal Hive::Schemas::WorkflowNewErrorKind::USAGE,
                 command.send(:error_kind_for, error)
  end

  def test_new_collision_proposes_deterministic_available_id
    with_initialized_project do |project_root|
      Hive::Commands::Workflow.new!("editorial", project_root: project_root, stdout: StringIO.new)
      Hive::Commands::Workflow.new!("editorial-2", project_root: project_root, stdout: StringIO.new)
      before = project_snapshot(project_root)

      error = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new!("editorial", project_root: project_root, stdout: StringIO.new)
      end

      assert_equal "editorial-3", error.suggested_id
      assert_includes error.message, "try \"editorial-3\""
      assert_equal before, project_snapshot(project_root)
    end
  end

  private

  def with_initialized_project
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call }
        yield project_root
      end
    end
  end

  def write_editorial_workflow(project_root)
    workflows = File.join(project_root, ".hive-state", "workflows")
    instructions = File.join(workflows, "editorial")
    FileUtils.mkdir_p(instructions)
    File.write(File.join(instructions, "research.md"), "Research the request.\n")
    File.write(File.join(instructions, "draft.md"), "Draft from research.md.\n")
    descriptor = File.join(workflows, "editorial.yml")
    File.write(descriptor, <<~YAML)
      id: editorial
      stages:
        - name: research
          kind: agent
          state_file: research.md
          instruction: editorial/research.md
          permissions: yolo
        - name: draft
          kind: agent
          state_file: draft.md
          instruction: editorial/draft.md
          permissions: yolo
        - name: approval
          kind: human
          state_file: approval.md
          input: draft.md
          outcomes:
            approve:
              complete: true
              artifact: draft.md
            reject:
              to: draft
    YAML
    descriptor
  end

  def project_snapshot(project_root)
    root = File.join(project_root, ".hive-state", "workflows")
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
      next if File.directory?(path)

      [ path.delete_prefix("#{root}/"), File.binread(path) ]
    end
  end

  def state_head(project_root)
    run!("git", "-C", File.join(project_root, ".hive-state"), "rev-parse", "HEAD").strip
  end
end
