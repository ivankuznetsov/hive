require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/approve"
require "hive/commands/decide"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"
require "hive/commands/status"
require "hive/daemon/policy"
require "hive/cli"

class DecideTest < Minitest::Test
  include HiveTestHelper

  SLUG_PATTERN = "editorial-probe-*".freeze

  def test_entering_human_stage_waits_without_dispatch_and_surfaces_outcomes
    with_editorial_task do |_dir, approval, slug|
      task = Hive::Task.new(approval)
      marker = Hive::Markers.current(task.state_file)
      action = Hive::TaskAction.for(task, marker)

      assert_equal :waiting, marker.name
      assert_match(/\A[0-9a-f]{16}\z/, marker.attrs.fetch("decision_id"))
      assert_equal "needs_input", action.key
      assert_nil action.command
      assert_equal %w[approve reject], action.allowed_outcomes.map { |entry| entry.fetch("name") }
      assert_equal :skip, Hive::Daemon::Policy.decide(
        action: action.key, stage: "3-approval", workflow: "editorial",
        command: action.command, state_file_mtime: File.mtime(task.state_file),
        last_dispatched_state_file_mtime: nil, now: Time.now
      )

      out, = capture_io { Hive::Commands::Run.new(slug, json: true).call }
      payload = JSON.parse(out)
      assert_equal true, payload.fetch("ok")
      assert_equal "waiting", payload.fetch("marker")
      assert_equal "human_decision_required", payload.dig("next_action", "reason")
      assert_equal %w[approve reject], payload.fetch("allowed_outcomes").map { |entry| entry.fetch("name") }
      assert_schema_valid("hive-run", payload)
    end
  end

  def test_approve_records_publish_ready_artifact_and_completes_idempotently
    with_editorial_task do |dir, approval, slug|
      out, = capture_io do
        Hive::Commands::Decide.new(slug, "approve", from: "approval", note: "Ready for the editor", json: true).call
      end
      payload = JSON.parse(out)

      assert_equal true, payload.fetch("ok")
      assert_equal true, payload.fetch("applied")
      assert_equal true, payload.fetch("completed")
      assert_equal "draft.md", payload.fetch("artifact")
      assert_equal "3-approval", payload.fetch("current_stage")
      assert_schema_valid("hive-decide", payload)

      task = Hive::Task.new(approval)
      assert_equal :complete, Hive::Markers.current(task.state_file).name
      record = Hive::Commands::Decide.latest_record(task.state_file)
      assert_equal "approve", record.fetch("outcome")
      assert_equal "Ready for the editor", record.fetch("note")
      assert_equal "draft.md", record.fetch("artifact")
      assert_equal "publish_ready", record.fetch("artifact_status")
      assert_equal "approval", record.fetch("from")
      assert File.file?(File.join(approval, "draft.md"))
      refute Dir.exist?(File.join(dir, ".hive-state", "stages", "4-publish"))

      retry_out, = capture_io do
        Hive::Commands::Decide.new(slug, "approve", from: "approval", note: "Ready for the editor", json: true).call
      end
      retry_payload = JSON.parse(retry_out)
      assert_equal false, retry_payload.fetch("applied")
      assert_equal true, retry_payload.fetch("noop")
      assert_equal record.fetch("decision_id"), retry_payload.fetch("decision_id")

      assert_raises(Hive::WrongStage) do
        Hive::Commands::Decide.new(slug, "reject", from: "approval").call
      end
    end
  end

  def test_approve_requires_non_empty_artifact_without_mutation
    with_editorial_task do |_dir, approval, slug|
      draft = File.join(approval, "draft.md")
      File.write(draft, "")
      before = File.binread(File.join(approval, "approval.md"))

      error = assert_raises(Hive::WrongStage) do
        Hive::Commands::Decide.new(slug, "approve", from: "approval").call
      end

      assert_includes error.message, "non-empty artifact"
      assert_equal before, File.binread(File.join(approval, "approval.md"))
      assert_equal :waiting, Hive::Markers.current(File.join(approval, "approval.md")).name
      assert File.directory?(approval)
    end
  end

  def test_reject_records_decision_returns_to_draft_and_retries_as_noop
    with_editorial_task do |dir, approval, slug|
      out, = capture_io do
        Hive::CLI.start(
          [ "decide", slug, "reject", "--from", "3-approval", "--note", "Strengthen the lead", "--json" ]
        )
      end
      payload = JSON.parse(out)
      draft = File.join(dir, ".hive-state", "stages", "2-draft", slug)

      assert_equal true, payload.fetch("applied")
      assert_equal false, payload.fetch("completed")
      assert_equal "2-draft", payload.fetch("current_stage")
      assert File.directory?(draft)
      refute File.exist?(approval)
      assert_equal :waiting, Hive::Markers.current(File.join(draft, "draft.md")).name
      record = Hive::Commands::Decide.latest_record(File.join(draft, "approval.md"))
      assert_equal "reject", record.fetch("outcome")
      assert_equal "Strengthen the lead", record.fetch("note")
      assert_equal "draft", record.fetch("to")

      retry_out, = capture_io do
        Hive::Commands::Decide.new(slug, "reject", from: "approval", note: "Strengthen the lead", json: true).call
      end
      retry_payload = JSON.parse(retry_out)
      assert_equal true, retry_payload.fetch("noop")
      assert_equal false, retry_payload.fetch("applied")
      assert_equal "2-draft", retry_payload.fetch("current_stage")

      assert_raises(Hive::WrongStage) do
        Hive::Commands::Decide.new(slug, "approve", from: "approval").call
      end
    end
  end

  def test_status_and_operational_status_expose_human_outcomes
    with_editorial_task do |_dir, _approval, slug|
      status_out, = capture_io { Hive::Commands::Status.new(json: true).call }
      row = JSON.parse(status_out).fetch("projects").flat_map { |project| project.fetch("tasks") }
                     .find { |task| task.fetch("slug") == slug }
      assert_equal "needs_input", row.fetch("action")
      assert_nil row.fetch("suggested_command")
      assert_equal %w[approve reject], row.fetch("outcomes").map { |entry| entry.fetch("name") }
      assert_schema_valid("hive-status", JSON.parse(status_out))

      operational_out, = capture_io { Hive::Commands::Status.new(json: true, operational: true).call }
      operational = JSON.parse(operational_out)
      projected = operational.fetch("tasks").find { |task| task.dig("identity", "slug") == slug }
      assert_equal "waiting_on_you", projected.fetch("state")
      assert_equal %w[approve reject], projected.dig("position", "allowed_outcomes").map { |entry| entry.fetch("name") }
      assert_nil projected.fetch("action")
      assert_schema_valid("hive-operational-status", operational)
    end
  end

  private

  def editorial_workflow
    Hive::Workflow.new(
      id: :editorial,
      stages: [
        Hive::Workflow::Stage.new(name: "research", index: 1, state_file: "research.md", kind: :agent, skill: "/research"),
        Hive::Workflow::Stage.new(name: "draft", index: 2, state_file: "draft.md", kind: :agent, skill: "/draft"),
        Hive::Workflow::Stage.new(
          name: "approval", index: 3, state_file: "approval.md", kind: :human, input: "draft.md",
          outcomes: {
            "approve" => Hive::Workflow::Outcome.new(name: "approve", complete: true, artifact: "draft.md"),
            "reject" => Hive::Workflow::Outcome.new(name: "reject", to: "draft")
          }.freeze
        )
      ]
    )
  end

  def with_editorial_task
    descriptor = editorial_workflow
    with_registered_workflow(descriptor) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir, agent_skill_preflight: false).call }
          project = File.basename(dir)
          capture_io { Hive::Commands::New.new(project, "editorial probe", workflow: "editorial").call }
          research = Dir[File.join(dir, ".hive-state", "stages", "1-research", SLUG_PATTERN)].fetch(0)
          slug = File.basename(research)
          Hive::Markers.set(File.join(research, "research.md"), :complete)
          capture_io { Hive::Commands::Approve.new(slug, from: "research").call }
          draft = File.join(dir, ".hive-state", "stages", "2-draft", slug)
          File.write(File.join(draft, "draft.md"), "# Draft\n\nPublishable copy.\n")
          Hive::Markers.set(File.join(draft, "draft.md"), :complete)
          capture_io { Hive::Commands::Approve.new(slug, from: "draft").call }
          approval = File.join(dir, ".hive-state", "stages", "3-approval", slug)

          yield dir, approval, slug
        end
      end
    end
  end

  def assert_schema_valid(name, payload)
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))
    errors = schemer.validate(payload).to_a
    assert_empty errors, "#{name} payload errors: #{errors.map { |error| error['error'] }.inspect}"
  end
end
