require "test_helper"
require "json"
require "json_schemer"
require "hive/agent_skills/canonical_skill"
require "hive/commands/approve"
require "hive/commands/decide"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/status"
require "hive/commands/workflow"
require "hive/task_meta"

class WorkflowCreatorE2ETest < Minitest::Test
  include HiveTestHelper

  EDITORIAL_PROMPT =
    "Create a three-stage editorial workflow that researches, drafts, and requires approval before publishing".freeze

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_ae1_creation_only_uses_scaffold_and_validation_without_a_task
    with_initialized_project do |project_root, _project|
      commands = []
      payload = create_editorial(project_root, commands: commands)

      assert_equal [
        [ "workflow", "new", "editorial" ],
        [ "workflow", "validate", "editorial", "--json" ]
      ], commands
      assert_equal %w[research draft approval], payload.fetch("stages").map { |stage| stage.fetch("name") }
      assert_equal [
        [ "research", "draft" ],
        [ "draft", "approval" ]
      ], payload.fetch("automatic_edges").map { |edge| edge.values_at("from", "to") }
      assert_equal [
        [ "approval", "approve", true, "draft.md", nil ],
        [ "approval", "reject", false, nil, "draft" ]
      ], payload.fetch("human_outcomes").map { |outcome|
        outcome.values_at("stage", "name", "complete", "artifact", "to")
      }
      assert_empty task_folders(project_root)
      assert_schema_valid("hive-workflow-validate", payload)

      creator = Hive::AgentSkills::CanonicalSkill.new.rendered_canonical_files
                                                   .fetch("references/workflow-creator.md")
      assert_includes creator, "No task by default"
      assert_includes creator, "hive new PROJECT --workflow ID"
      assert_includes creator, "Never publish externally"
      assert_operator creator.index("hive workflow new"), :<, creator.index("hive workflow validate")
      assert_operator creator.index("hive workflow validate"), :<,
                      creator.index('git -C "$state_root" commit')
      assert_operator creator.index('git -C "$state_root" commit'), :<,
                      creator.index("hive new PROJECT --workflow ID")
    end
  end

  def test_ae1_and_ae2_approval_and_rejection_are_durable_and_closed
    with_initialized_project do |project_root, project|
      create_editorial(project_root)

      approved = create_task(project, "approved-editorial", key: "creator:approved")
      approval = advance_to_approval(project_root, approved.fetch("slug"))
      approve_payload = decide(approved.fetch("slug"), "approve", note: "Publish-ready")
      record = Hive::Commands::Decide.latest_record(File.join(approval, "approval.md"))

      assert_equal true, approve_payload.fetch("completed")
      assert_equal "draft.md", approve_payload.fetch("artifact")
      assert_equal "approve", record.fetch("outcome")
      assert_equal "publish_ready", record.fetch("artifact_status")
      assert_equal "draft.md", record.fetch("artifact")
      refute Dir.exist?(File.join(project_root, ".hive-state", "stages", "4-publish"))

      rejected = create_task(project, "rejected-editorial", key: "creator:rejected")
      rejected_approval = advance_to_approval(project_root, rejected.fetch("slug"))
      reject_payload = decide(rejected.fetch("slug"), "reject", note: "Strengthen the evidence")
      draft = task_folder(project_root, "2-draft", rejected.fetch("slug"))
      reject_record = Hive::Commands::Decide.latest_record(File.join(draft, "approval.md"))

      assert_equal false, reject_payload.fetch("completed")
      assert_equal "2-draft", reject_payload.fetch("current_stage")
      assert_equal :waiting, Hive::Markers.current(File.join(draft, "draft.md")).name
      assert_equal "reject", reject_record.fetch("outcome")
      assert_equal "draft", reject_record.fetch("to")
      refute Dir.exist?(rejected_approval)
    end
  end

  def test_ae3_collision_is_byte_identical_and_proposes_available_id
    with_initialized_project do |project_root, _project|
      create_editorial(project_root)
      before = workflow_snapshot(project_root)

      error = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new!(
          "editorial", project_root: project_root, stdout: StringIO.new
        )
      end

      assert_equal "editorial-2", error.suggested_id
      assert_includes error.message, 'try "editorial-2"'
      assert_equal before, workflow_snapshot(project_root)
    end
  end

  def test_ae4_fresh_minimal_preview_is_no_write_until_confirmed
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        before = repository_snapshot(project_root)
        preview_out, preview_err = capture_io do
          Hive::Commands::Init.new(
            project_root, new_workflow: "editorial", minimal: true, preview: true,
            json: true, agent_skill_preflight: false
          ).call
        end
        preview = JSON.parse(preview_out)

        assert_empty preview_err
        assert_equal before, repository_snapshot(project_root)
        assert_equal false, preview.fetch("task_creation")
        assert_equal false, preview.dig("services", "daemon_install")
        assert_equal false, preview.dig("background_automation", "daemon_dispatch")
        assert_schema_valid("hive-init-preview", preview)

        execute_out, execute_err = capture_io do
          Hive::Commands::Init.new(
            project_root, new_workflow: "editorial", minimal: true,
            json: true, agent_skill_preflight: false
          ).call
        end
        execute = JSON.parse(execute_out)
        assert_empty execute_err
        assert_equal true, execute.fetch("minimal")

        author_editorial(project_root)
        validation = validate_editorial(project_root)
        assert_equal %w[research draft approval], validation.fetch("stages").map { |stage| stage.fetch("name") }
        assert_empty task_folders(project_root)
      end
    end
  end

  def test_ae5_explicit_task_creation_is_idempotent_after_movement
    with_initialized_project do |project_root, project|
      create_editorial(project_root)
      key = "workflow-creator:editorial:stable"
      first = create_task(project, "idempotent-editorial", key: key)
      research = task_folder(project_root, "1-research", first.fetch("slug"))
      Hive::Markers.set(File.join(research, "research.md"), :complete)
      capture_io { Hive::Commands::Approve.new(first.fetch("slug"), from: "research").call }

      retry_payload = create_task(project, "idempotent-editorial", key: key)
      status_out, = capture_io { Hive::Commands::Status.new(json: true, operational: true).call }
      operational = JSON.parse(status_out)
      live = operational.fetch("tasks").find do |task|
        task.dig("identity", "slug") == first.fetch("slug")
      end

      assert_equal true, first.fetch("created")
      assert_equal false, retry_payload.fetch("created")
      assert_equal first.fetch("slug"), retry_payload.fetch("slug")
      assert_equal "2-draft", retry_payload.fetch("current_stage")
      assert_equal 1, idempotent_task_folders(project_root, key).size
      assert_equal "2-draft", live.dig("position", "stage")
      assert_schema_valid("hive-new", retry_payload)
      assert_schema_valid("hive-operational-status", operational)
    end
  end

  def test_invalid_generated_yaml_stops_before_task_creation
    with_initialized_project do |project_root, _project|
      Hive::Commands::Workflow.new!(
        "editorial", project_root: project_root, stdout: StringIO.new
      )
      descriptor = workflow_descriptor(project_root)
      File.write(descriptor, "id: editorial\nstages: [\n")
      before = workflow_snapshot(project_root)

      assert_raises(Hive::ConfigError) { validate_editorial(project_root) }
      assert_equal before, workflow_snapshot(project_root)
      assert_empty task_folders(project_root)
    end
  end

  private

  def with_initialized_project
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call }
        yield project_root, File.basename(project_root)
      end
    end
  end

  def create_editorial(project_root, commands: nil)
    commands&.push([ "workflow", "new", "editorial" ])
    Hive::Commands::Workflow.new!(
      "editorial", project_root: project_root, stdout: StringIO.new
    )
    author_editorial(project_root)
    commands&.push([ "workflow", "validate", "editorial", "--json" ])
    validate_editorial(project_root)
  end

  def author_editorial(project_root)
    descriptor = workflow_descriptor(project_root)
    instruction_dir = File.join(File.dirname(descriptor), "editorial")
    FileUtils.rm_f(File.join(instruction_dir, "work.md"))
    File.write(File.join(instruction_dir, "research.md"), "Research the request and write research.md.\n")
    File.write(File.join(instruction_dir, "draft.md"), "Use research.md to write a publish-ready draft.md.\n")
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
    Hive::Workflows::Project.reset!
  end

  def validate_editorial(project_root)
    Hive::Commands::Workflow.new(
      "validate", "editorial", project_root: project_root,
      json: true, stdout: StringIO.new
    ).call!
  end

  def create_task(project, slug, key:)
    out, err = capture_io do
      Hive::Commands::New.new(
        project, EDITORIAL_PROMPT, slug_override: slug, workflow: "editorial",
        idempotency_key: key, json: true
      ).call!
    end
    assert_empty err
    JSON.parse(out)
  end

  def advance_to_approval(project_root, slug)
    research = task_folder(project_root, "1-research", slug)
    Hive::Markers.set(File.join(research, "research.md"), :complete)
    capture_io { Hive::Commands::Approve.new(slug, from: "research").call }
    draft = task_folder(project_root, "2-draft", slug)
    File.write(File.join(draft, "draft.md"), "# Draft\n\nPublishable copy.\n")
    Hive::Markers.set(File.join(draft, "draft.md"), :complete)
    capture_io { Hive::Commands::Approve.new(slug, from: "draft").call }
    task_folder(project_root, "3-approval", slug)
  end

  def decide(slug, outcome, note:)
    task = Hive::TaskResolver.new(slug).resolve
    decision_id = Hive::Markers.current(task.state_file).attrs.fetch("decision_id")
    out, err = capture_io do
      Hive::Commands::Decide.new(
        slug, outcome, from: "approval", decision_id: decision_id, note: note, json: true
      ).call
    end
    assert_empty err
    payload = JSON.parse(out)
    assert_schema_valid("hive-decide", payload)
    payload
  end

  def workflow_descriptor(project_root)
    File.join(project_root, ".hive-state", "workflows", "editorial.yml")
  end

  def task_folder(project_root, stage, slug)
    File.join(project_root, ".hive-state", "stages", stage, slug)
  end

  def task_folders(project_root)
    Dir.glob(File.join(project_root, ".hive-state", "stages", "*", "*")).select do |folder|
      File.file?(File.join(folder, "meta.yml"))
    end
  end

  def idempotent_task_folders(project_root, key)
    task_folders(project_root).select do |folder|
      Hive::TaskMeta.read(folder)[:idempotency_key] == key
    end
  end

  def workflow_snapshot(project_root)
    root = File.join(project_root, ".hive-state", "workflows")
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
      next if File.directory?(path)

      [ path.delete_prefix("#{root}/"), File.binread(path) ]
    end
  end

  def repository_snapshot(project_root)
    {
      "head" => run!("git", "-C", project_root, "rev-parse", "HEAD").strip,
      "status" => run!("git", "-C", project_root, "status", "--porcelain"),
      "branches" => run!("git", "-C", project_root, "branch", "--format=%(refname:short)")
    }
  end

  def assert_schema_valid(name, payload)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))
    errors = schema.validate(payload).to_a
    assert_empty errors, "#{name}: #{errors.inspect}"
  end
end
