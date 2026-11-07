# frozen_string_literal: true

require "test_helper"
require "hive/remote/command_service"
require "hive/remote/read_service"
require "hive/commands/init"
require "hive/runtime_control_plane/command_schema_installation"

class RemoteCommandAdmissionGuardsTest < Minitest::Test
  include HiveTestHelper

  def test_canonical_effects_are_closed_and_never_derive_force
    service = Hive::Remote::CommandService
    project = { "name" => "demo" }
    row = { "stage" => "2-brainstorm", "workflow" => "coding", "marker" => "complete" }
    { Hive::Schemas::TaskActionKind::OUTCOME_EVIDENCE_REWORK => "evidence_rework", "ready_to_run" => "run" }.each do |action, kind|
      assert_equal({ "kind" => kind, "force" => false }, service.effect_for(task: nil, row: row.merge("action" => action), action_id: "workflow.advance", project: project))
    end
    assert_raises(Hive::OperationalActionUsageError) do
      service.effect_for(task: nil, row: row.merge("action" => "release"), action_id: "workflow.advance", project: project)
    end
    inbox = row.merge("stage" => "1-inbox", "action" => "ready_to_brainstorm")
    error = assert_raises(Hive::OperationalActionUsageError) do
      service.effect_for(task: nil, row: inbox, action_id: "workflow.advance", project: project)
    end
    assert_includes error.message, "locally"
    assert_raises(Hive::OperationalActionUsageError) do
      service.effect_for(task: nil, row: row.merge("stage" => "9-done"), action_id: Hive::OperationalAction::RETRY_ACTION_ID, project: project)
    end
    original = Hive::Recovery::RetryPolicy.method(:verb_for)
    Hive::Recovery::RetryPolicy.define_singleton_method(:verb_for) { |*_, **| "brainstorm" }
    error = assert_raises(Hive::OperationalActionUsageError) do
      service.effect_for(task: nil, row: inbox, action_id: Hive::OperationalAction::RETRY_ACTION_ID, project: project)
    end
    assert_includes error.message, "locally"
  ensure
    Hive::Recovery::RetryPolicy.define_singleton_method(:verb_for, original) if original
  end

  def test_worker_rechecks_identity_effect_and_approval_marker
    with_task do |project, task, _service, _store|
      name = project.fetch("name")
      descriptor = Hive::OperationalAction.descriptor_for_task(task, project: name)
      row = Hive::OperationalAction.observed_row(task, project: name)
      authority = { "project" => name, "task_id" => task.id, "slug" => task.slug,
                   "action_id" => descriptor.fetch("action_id"), "observation" => descriptor.fetch("observation_token"),
                   "effect" => Hive::Remote::CommandService.effect_for(task: task, row: row, action_id: descriptor.fetch("action_id"), project: project),
                   "execution_observation" => Hive::Remote::CommandService.execution_observation(task, row) }
      verify = ->(binding) do
        Hive::Remote::CommandService.verify_action!(task: task, project: name,
          action_id: descriptor.fetch("action_id"), observation: descriptor.fetch("observation_token"), authority: binding)
      end
      assert verify.call(authority)
      assert_raises(Hive::StaleOperationalObservation) { verify.call(authority.merge("task_id" => "foreign")) }
      assert_raises(Hive::StaleOperationalObservation) { verify.call(authority.merge("effect" => { "kind" => "approve", "force" => false })) }
      approval = authority.merge("stage" => "2-brainstorm", "generation" => "stale")
      assert_raises(Hive::StaleOperationalObservation) do
        Hive::Remote::CommandService.verify_approval!(task: task, project: name, authority: approval)
      end
      File.write(task.state_file, "# Brainstorm\n### Q1. Which color?\n### A1.\n<!-- WAITING -->\n")
      assert_raises(Hive::StaleOperationalObservation) { verify.call(authority) }
      approval["generation"] = Hive::Remote::CommandService.generation_for(task, project: name)
      assert_raises(Hive::OperationalActionUsageError) do
        Hive::Remote::CommandService.verify_approval!(task: task, project: name, authority: approval)
      end
      reader = Hive::Remote::ReadService.new
      assert_nil reader.action(project: project, task: task)
      assert_equal 1, reader.questions(project: project, task: task).fetch("slot_count")
    end
  end

  def test_changed_task_identity_is_rejected_at_locked_admission
    with_task do |project, task, service, store|
      descriptor = Hive::OperationalAction.descriptor_for_task(task, project: project.fetch("name"))
      old_id = task.id
      Hive::TaskMeta.write(task.folder, id: old_id + 1, slug: task.slug, display_name: "Replacement", workflow: "coding")
      assert_raises(Hive::StaleOperationalObservation) do
        service.action(project: project, task: task, action_id: descriptor.fetch("action_id"),
          observation: descriptor.fetch("observation_token"), idempotency_key: "stale-identity",
          principal: "installation:test:token:operator", scopes: [ "act" ])
      end
      assert_equal 0, store.database.read { |db| db[:dispatch_requests].count }
    end
  end

  def test_untyped_targets_and_malformed_observations_never_reach_dispatch
    with_task do |project, task, service, store|
      assert_raises(Hive::OperationalActionUsageError) do
        service.action(project: project, task: task, action_id: "workflow.advance", observation: "invalid",
          idempotency_key: "invalid-observation", principal: "installation:test:token:operator", scopes: [ "act" ])
      end
      assert_raises(Hive::InvalidTaskPath) do
        service.answer(project: project, task: Object.new, binding: "binding", answer: "literal",
          idempotency_key: "invalid-target", principal: "installation:test:token:operator", scopes: [ "answer" ])
      end
      assert_raises(Hive::InvalidTaskPath) { Hive::Remote::ReadService.new.action(project: project, task: Object.new) }
      assert_equal 0, store.database.read { |db| db[:dispatch_requests].count }
    end
  end

  private

  def with_task
    with_tmp_global_config do
      with_tmp_git_repo do |root|
        capture_io { Hive::Commands::Init.new(root).call }
        project = Hive::Config.registered_projects.find { |entry| entry.fetch("path") == root }
        config_path = File.join(project.fetch("hive_state_path"), "config.yml")
        config = YAML.safe_load_file(config_path)
        config["command_receipts"] = { "keyed_intake_enabled" => true }
        File.write(config_path, config.to_yaml)
        database = Hive::RuntimeControlPlane.database.open!
        Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(database: database,
          package_coordinates: { version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "a" * 64 })
        folder = File.join(project.fetch("hive_state_path"), "stages", "2-brainstorm", "guards-260923-abcd")
        Hive::TaskMeta.write(folder, id: 42, slug: File.basename(folder), display_name: "Guard fixture", workflow: "coding")
        File.write(File.join(folder, "brainstorm.md"), "# Brainstorm\n<!-- COMPLETE -->\n")
        store = Hive::CommandReceiptStore.new(database: database)
        yield project, Hive::Task.new(folder), Hive::Remote::CommandService.new(store: store), store
      end
    end
  end
end
